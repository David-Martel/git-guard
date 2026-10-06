//! Read-only reserved-path inventory; never deletes or approves a candidate.
//!
//! Compile separately with `rustc --edition=2021 -D warnings -O <this-file>`.
//! Arguments are ROOT GIT_DIR COMMON_DIR: absolute physical paths already resolved by Git.
//! Successful stdout contains only absolute candidate paths, each terminated by NUL. Inventory
//! errors emit no candidate records. Consumers must check exit status before using output:
//! an output-device failure can still leave a partial stream. Stderr reports protected scopes.
//!
//! Qualified only for Linux x86_64/aarch64 with /proc available. User symlinks are never followed;
//! Linux-owned /proc/self/fd links anchor enumeration to open no-follow directory handles.
//! Observed directory/root replacement fails closed. This is not a filesystem snapshot or an
//! authorization to unlink: the existing shell's identity/size/type/UID gates remain mandatory.

#![forbid(unsafe_code)]

#[cfg(all(
    target_os = "linux",
    any(target_arch = "x86_64", target_arch = "aarch64")
))]
mod linux {
    use std::ffi::{OsStr, OsString};
    use std::fmt;
    use std::fs::{self, File, Metadata, OpenOptions, ReadDir};
    use std::io::{self, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    use std::path::{Component, Path, PathBuf};
    use std::time::Instant;

    // Linux asm-generic UAPI; x86_64/aarch64 use these values. Other targets are unqualified.
    // https://github.com/torvalds/linux/blob/master/include/uapi/asm-generic/fcntl.h
    const O_DIRECTORY: i32 = 1 << 16;
    const O_NOFOLLOW: i32 = 1 << 17;
    const O_PATH: i32 = 1 << 21;
    const MAX_DEPTH: usize = 1024;

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum ErrorKind {
        Usage,
        PathNotPhysical,
        Metadata,
        Enumeration,
        DirectoryChanged,
        RootChanged,
        DepthLimit,
        CounterOverflow,
        Output,
    }

    #[derive(Debug)]
    pub struct Error {
        pub kind: ErrorKind,
        path: Option<PathBuf>,
        source: Option<io::Error>,
    }

    impl Error {
        fn new(kind: ErrorKind, path: &Path) -> Self {
            Self {
                kind,
                path: Some(path.to_owned()),
                source: None,
            }
        }

        fn io(kind: ErrorKind, path: &Path, source: io::Error) -> Self {
            Self {
                kind,
                path: Some(path.to_owned()),
                source: Some(source),
            }
        }
    }

    impl fmt::Display for Error {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            write!(formatter, "ERROR_{:?}", self.kind)?;
            if let Some(path) = &self.path {
                write!(formatter, ": {path:?}")?;
            }
            if let Some(source) = &self.source {
                write!(formatter, ": {source}")?;
            }
            Ok(())
        }
    }

    impl std::error::Error for Error {
        fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
            self.source
                .as_ref()
                .map(|source| source as &dyn std::error::Error)
        }
    }

    #[derive(Debug)]
    struct Config {
        root: PathBuf,
        root_directory: File,
        git_dir: PathBuf,
        common_dir: PathBuf,
    }

    impl Config {
        fn from_args(mut args: impl Iterator<Item = OsString>) -> Result<Self, Error> {
            let usage = || Error {
                kind: ErrorKind::Usage,
                path: None,
                source: None,
            };
            let root = PathBuf::from(args.next().ok_or_else(usage)?);
            let git_dir = PathBuf::from(args.next().ok_or_else(usage)?);
            let common_dir = PathBuf::from(args.next().ok_or_else(usage)?);
            if args.next().is_some() || root.parent().is_none() {
                return Err(usage());
            }
            let root_directory = validate_physical(&root)?;
            validate_physical(&git_dir)?;
            validate_physical(&common_dir)?;
            Ok(Self {
                root,
                root_directory,
                git_dir,
                common_dir,
            })
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    struct Identity {
        device: u64,
        inode: u64,
    }

    impl Identity {
        fn of(metadata: &Metadata) -> Self {
            Self {
                device: metadata.dev(),
                inode: metadata.ino(),
            }
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum ProtectedKind {
        GitMetadata,
        Worktrees,
        NestedGit,
        BareGit,
    }

    #[derive(Debug)]
    struct ProtectedScope {
        path: PathBuf,
        kind: ProtectedKind,
    }

    #[derive(Debug, Default)]
    struct Inventory {
        candidates: Vec<PathBuf>,
        protected: Vec<ProtectedScope>,
        entries: u64,
        directories: u64,
    }

    struct Frame {
        directory: File,
        public_path: PathBuf,
        // Kernel-owned fd path; retains the parent handle throughout descent.
        entry_path: PathBuf,
        entries: ReadDir,
    }

    fn anchor(directory: &File) -> PathBuf {
        PathBuf::from(format!("/proc/self/fd/{}", directory.as_raw_fd()))
    }

    fn physical_directory(path: &Path) -> Result<File, Error> {
        if !path.is_absolute() {
            return Err(Error::new(ErrorKind::PathNotPhysical, path));
        }
        let mut file = directory(Path::new("/"), Path::new("/"))?;
        let mut public_path = PathBuf::from("/");
        for component in path.components() {
            match component {
                Component::RootDir => {}
                Component::Normal(name) => {
                    public_path.push(name);
                    file = directory(&anchor(&file).join(name), &public_path)?;
                }
                _ => return Err(Error::new(ErrorKind::PathNotPhysical, path)),
            }
        }
        Ok(file)
    }

    fn validate_physical(path: &Path) -> Result<File, Error> {
        if !path.is_absolute() {
            return Err(Error::new(ErrorKind::PathNotPhysical, path));
        }
        let physical =
            fs::canonicalize(path).map_err(|error| Error::io(ErrorKind::Metadata, path, error))?;
        if physical != path {
            return Err(Error::new(ErrorKind::PathNotPhysical, path));
        }
        physical_directory(path)
    }

    fn root_identity(config: &Config) -> Result<Identity, Error> {
        let held = config
            .root_directory
            .metadata()
            .map_err(|error| Error::io(ErrorKind::RootChanged, &config.root, error))?;
        let current = physical_directory(&config.root).map_err(|mut error| {
            error.kind = ErrorKind::RootChanged;
            error
        })?;
        let observed = current
            .metadata()
            .map_err(|error| Error::io(ErrorKind::RootChanged, &config.root, error))?;
        if Identity::of(&held) != Identity::of(&observed) {
            return Err(Error::new(ErrorKind::RootChanged, &config.root));
        }
        Ok(Identity::of(&held))
    }

    fn directory(path: &Path, public_path: &Path) -> Result<File, Error> {
        let before = fs::symlink_metadata(path)
            .map_err(|error| Error::io(ErrorKind::Metadata, public_path, error))?;
        if !before.is_dir() {
            return Err(Error::new(ErrorKind::DirectoryChanged, public_path));
        }
        // O_PATH allows protected-scope marker checks without requiring read permission.
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(O_PATH | O_DIRECTORY | O_NOFOLLOW)
            .open(path)
            .map_err(|error| Error::io(ErrorKind::Metadata, public_path, error))?;
        let observed = file
            .metadata()
            .map_err(|error| Error::io(ErrorKind::Metadata, public_path, error))?;
        if Identity::of(&before) != Identity::of(&observed) {
            return Err(Error::new(ErrorKind::DirectoryChanged, public_path));
        }
        Ok(file)
    }

    fn marker(path: &Path, public_path: &Path) -> Result<Option<Metadata>, Error> {
        match fs::symlink_metadata(path) {
            Ok(metadata) => Ok(Some(metadata)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(Error::io(ErrorKind::Metadata, public_path, error)),
        }
    }

    fn protected_directory(
        file: &File,
        public_path: &Path,
    ) -> Result<Option<ProtectedKind>, Error> {
        let base = anchor(file);
        if marker(&base.join(".git"), public_path)?.is_some() {
            return Ok(Some(ProtectedKind::NestedGit));
        }
        // A linked indicator is conservatively protected without following its target.
        let head = marker(&base.join("HEAD"), public_path)?;
        if !head.is_some_and(|m| m.is_file() || m.file_type().is_symlink()) {
            return Ok(None);
        }
        let objects = marker(&base.join("objects"), public_path)?;
        if !objects.is_some_and(|m| m.is_dir() || m.file_type().is_symlink()) {
            return Ok(None);
        }
        let refs = marker(&base.join("refs"), public_path)?;
        Ok(refs
            .filter(|m| m.is_dir() || m.file_type().is_symlink())
            .map(|_| ProtectedKind::BareGit))
    }

    fn reserved_leaf(name: &OsStr) -> bool {
        // Only Windows trailing spaces/dots are normalized: tabs/newlines remain significant.
        let leaf = trim_suffix(name.as_bytes());
        let stem = leaf.split(|byte| *byte == b'.').next().unwrap_or_default();
        let stem = trim_suffix(stem);
        [b"$null".as_slice(), b"nul", b"con", b"prn", b"aux"]
            .iter()
            .any(|reserved| stem.eq_ignore_ascii_case(reserved))
            || matches!(stem, [a, b, c, digit] if
                [*a, *b, *c].eq_ignore_ascii_case(b"com") && (b'1'..=b'9').contains(digit)
                || [*a, *b, *c].eq_ignore_ascii_case(b"lpt") && (b'1'..=b'9').contains(digit))
    }

    fn trim_suffix(mut bytes: &[u8]) -> &[u8] {
        while matches!(bytes.last(), Some(b' ' | b'.')) {
            bytes = bytes.split_last().map_or(&[], |(_, remaining)| remaining);
        }
        bytes
    }

    fn count(value: &mut u64, path: &Path) -> Result<(), Error> {
        *value = value
            .checked_add(1)
            .ok_or_else(|| Error::new(ErrorKind::CounterOverflow, path))?;
        Ok(())
    }

    fn frame(file: File, public_path: PathBuf, entry_path: PathBuf) -> Result<Frame, Error> {
        let entries = fs::read_dir(anchor(&file))
            .map_err(|error| Error::io(ErrorKind::Enumeration, &public_path, error))?;
        Ok(Frame {
            directory: file,
            public_path,
            entry_path,
            entries,
        })
    }

    fn inventory(config: &Config, before_finish: impl FnOnce()) -> Result<Inventory, Error> {
        let original_root = root_identity(config)?;
        let mut output = Inventory {
            directories: 1,
            ..Inventory::default()
        };
        let mut stack = vec![frame(
            config
                .root_directory
                .try_clone()
                .map_err(|error| Error::io(ErrorKind::Metadata, &config.root, error))?,
            config.root.clone(),
            config.root.clone(),
        )?];
        while let Some(current) = stack.last_mut() {
            if let Some(entry) = current.entries.next() {
                let entry = entry.map_err(|error| {
                    Error::io(ErrorKind::Enumeration, &current.public_path, error)
                })?;
                let name = entry.file_name();
                let public_path = current.public_path.join(&name);
                count(&mut output.entries, &public_path)?;
                if name == OsStr::new(".git")
                    || public_path == config.git_dir
                    || public_path == config.common_dir
                {
                    output.protected.push(ProtectedScope {
                        path: public_path,
                        kind: ProtectedKind::GitMetadata,
                    });
                    continue;
                }
                let kind = entry
                    .file_type()
                    .map_err(|error| Error::io(ErrorKind::Metadata, &public_path, error))?;
                if kind.is_dir()
                    && (name == OsStr::new("worktrees") || name == OsStr::new(".worktrees"))
                {
                    output.protected.push(ProtectedScope {
                        path: public_path,
                        kind: ProtectedKind::Worktrees,
                    });
                    continue;
                }
                if !kind.is_dir() {
                    if reserved_leaf(&name) {
                        output.candidates.push(public_path);
                    }
                    continue;
                }
                let entry_path = anchor(&current.directory).join(&name);
                let file = directory(&entry_path, &public_path)?;
                if let Some(kind) = protected_directory(&file, &public_path)? {
                    output.protected.push(ProtectedScope {
                        path: public_path,
                        kind,
                    });
                    continue;
                }
                if reserved_leaf(&name) {
                    output.candidates.push(public_path.clone());
                }
                if stack.len() >= MAX_DEPTH {
                    return Err(Error::new(ErrorKind::DepthLimit, &public_path));
                }
                count(&mut output.directories, &public_path)?;
                stack.push(frame(file, public_path, entry_path)?);
            } else {
                let observed = fs::symlink_metadata(&current.entry_path)
                    .map_err(|error| Error::io(ErrorKind::Metadata, &current.public_path, error))?;
                let held = current
                    .directory
                    .metadata()
                    .map_err(|error| Error::io(ErrorKind::Metadata, &current.public_path, error))?;
                if !observed.is_dir() || Identity::of(&observed) != Identity::of(&held) {
                    return Err(Error::new(
                        ErrorKind::DirectoryChanged,
                        &current.public_path,
                    ));
                }
                stack.pop();
            }
        }
        before_finish();
        if root_identity(config)? != original_root {
            return Err(Error::new(ErrorKind::RootChanged, &config.root));
        }
        output
            .candidates
            .sort_by(|a, b| a.as_os_str().as_bytes().cmp(b.as_os_str().as_bytes()));
        output.candidates.dedup();
        output.protected.sort_by(|a, b| {
            a.path
                .as_os_str()
                .as_bytes()
                .cmp(b.path.as_os_str().as_bytes())
        });
        Ok(output)
    }

    fn emit(
        output: &Inventory,
        stdout: &mut impl Write,
        stderr: &mut impl Write,
    ) -> Result<(), Error> {
        for scope in &output.protected {
            writeln!(
                stderr,
                "PRESERVED_SCOPE: {:?}: {:?}",
                scope.kind, scope.path
            )
            .map_err(|error| Error::io(ErrorKind::Output, &scope.path, error))?;
        }
        writeln!(
            stderr,
            "INVENTORY_OK: entries={} directories={} candidates={} pruned={}",
            output.entries,
            output.directories,
            output.candidates.len(),
            output.protected.len()
        )
        .map_err(|error| Error::io(ErrorKind::Output, Path::new("stderr"), error))?;
        for path in &output.candidates {
            stdout
                .write_all(path.as_os_str().as_bytes())
                .and_then(|()| stdout.write_all(&[0]))
                .map_err(|error| Error::io(ErrorKind::Output, path, error))?;
        }
        stdout
            .flush()
            .map_err(|error| Error::io(ErrorKind::Output, Path::new("stdout"), error))
    }

    pub fn run(args: impl Iterator<Item = OsString>) -> Result<(), Error> {
        let started = Instant::now();
        let config = Config::from_args(args)?;
        let output = inventory(&config, || {})?;
        emit(&output, &mut io::stdout().lock(), &mut io::stderr().lock())?;
        writeln!(
            io::stderr().lock(),
            "INVENTORY_TIME_US: {}",
            started.elapsed().as_micros()
        )
        .map_err(|error| Error::io(ErrorKind::Output, Path::new("stderr"), error))
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::os::unix::ffi::OsStringExt;
        use std::os::unix::fs::{symlink, PermissionsExt};
        use std::sync::atomic::{AtomicU64, Ordering};

        static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

        struct Fixture {
            base: PathBuf,
            config: Config,
        }

        impl Fixture {
            fn new(label: &str) -> Self {
                let repository = Path::new(file!())
                    .canonicalize()
                    .unwrap()
                    .parent()
                    .unwrap()
                    .parent()
                    .unwrap()
                    .parent()
                    .unwrap()
                    .to_owned();
                let base = repository
                    .join("worktrees/.tmp-reserved-path-inventory-20261003")
                    .join(format!(
                        "test-{}-{}-{label}",
                        std::process::id(),
                        NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
                    ));
                fs::create_dir_all(&base).unwrap();
                let root = base.join("root");
                fs::create_dir(&root).unwrap();
                let git = root.join(".git");
                fs::create_dir(&git).unwrap();
                let config = Config::from_args(
                    [
                        root.into_os_string(),
                        git.clone().into_os_string(),
                        git.into_os_string(),
                    ]
                    .into_iter(),
                )
                .unwrap();
                Self { base, config }
            }

            fn file(&self, name: impl AsRef<Path>, bytes: &[u8]) -> PathBuf {
                let path = self.config.root.join(name);
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(&path, bytes).unwrap();
                path
            }
        }

        // Fixtures remain in ignored, process-unique scratch as review evidence. No test
        // invokes the installed hook, Git, a deletion API, or modifies a global environment.
        fn capture(
            config: &Config,
            before_finish: impl FnOnce(),
        ) -> (Result<(), Error>, Vec<u8>, Vec<u8>) {
            let mut stdout = Vec::new();
            let mut stderr = Vec::new();
            let result = inventory(config, before_finish)
                .and_then(|output| emit(&output, &mut stdout, &mut stderr));
            (result, stdout, stderr)
        }

        #[test]
        fn exact_suffix_normalization_preserves_prefix_and_unicode_false_positives() {
            for name in [
                "nul",
                "NuL.txt",
                "CON .txt",
                "AUX... ",
                "PrN. ",
                "$null",
                "$NULL.log",
                "COM1",
                "cOm9.txt",
                "LPT1 .log",
                "lpt9",
            ] {
                assert!(reserved_leaf(OsStr::new(name)), "{name:?}");
            }
            for name in [
                "nulordinary",
                "nulé",
                "nul\t",
                "nul\n",
                "COM10",
                "COM0",
                "COM¹",
                "LPT0",
                "$nullish",
                ".NUL",
                "configuration",
                "auxiliary",
                "",
            ] {
                assert!(!reserved_leaf(OsStr::new(name)), "{name:?}");
            }
            assert!(reserved_leaf(&OsString::from_vec(b"NUL.\xff".to_vec())));
            assert!(!reserved_leaf(&OsString::from_vec(b"NUL\xff".to_vec())));
        }

        #[test]
        fn preserves_raw_path_bytes_newlines_and_deterministic_nul_record_order() {
            let fixture = Fixture::new("bytes");
            let mut expected = vec![
                fixture.file("é•仓/NUL.txt", b"meaningful data"),
                fixture.file("directory\nwith newline/COM1.txt", b""),
                fixture.file(
                    PathBuf::from(OsString::from_vec(b"raw-\xff/NUL.\xfe".to_vec())),
                    b"",
                ),
                fixture.file("$NULL", b""),
            ];
            fixture.file("nulordinary", b"ordinary");
            fixture.file("nulé", b"unicode");
            let hardlink = fixture.config.root.join("LPT9.log");
            fs::hard_link(expected.first().unwrap(), &hardlink).unwrap();
            expected.push(hardlink);
            expected.sort_by(|a, b| a.as_os_str().as_bytes().cmp(b.as_os_str().as_bytes()));
            let (result, stdout, _) = capture(&fixture.config, || {});
            result.unwrap();
            let mut oracle = Vec::new();
            for path in &expected {
                oracle.extend_from_slice(path.as_os_str().as_bytes());
                oracle.push(0);
            }
            assert_eq!(stdout, oracle);
            assert_eq!(capture(&fixture.config, || {}).1, oracle);
            assert_eq!(
                fs::read(fixture.config.root.join("é•仓/NUL.txt")).unwrap(),
                b"meaningful data"
            );
            assert!(expected.iter().all(|path| path.exists()));
        }

        #[test]
        fn prunes_metadata_worktree_containers_nested_markers_and_bare_scopes() {
            let fixture = Fixture::new("scopes");
            for path in [
                ".git/nul",
                "worktrees/other/CON.txt",
                ".worktrees/other/NUL",
                "nested-file/.git",
                "nested-file/NUL",
                "nested-dir/.git/NUL",
                "bare/HEAD",
                "bare/objects/NUL",
                "bare/refs/NUL",
                "AUX/.git",
                "AUX/NUL",
            ] {
                fixture.file(path, b"");
            }
            let ordinary = fixture.file("owned/PRN.log", b"");
            let output = inventory(&fixture.config, || {}).unwrap();
            assert_eq!(output.candidates, [ordinary]);
            for (path, kind) in [
                (".git", ProtectedKind::GitMetadata),
                ("worktrees", ProtectedKind::Worktrees),
                (".worktrees", ProtectedKind::Worktrees),
                ("nested-file", ProtectedKind::NestedGit),
                ("nested-dir", ProtectedKind::NestedGit),
                ("bare", ProtectedKind::BareGit),
                ("AUX", ProtectedKind::NestedGit),
            ] {
                assert!(
                    output
                        .protected
                        .iter()
                        .any(|scope| scope.path == fixture.config.root.join(path)
                            && scope.kind == kind),
                    "{path}"
                );
            }
            let (_, _, stderr) = capture(&fixture.config, || {});
            let diagnostics = String::from_utf8(stderr).unwrap();
            assert!(diagnostics.contains("PRESERVED_SCOPE: BareGit"));
            assert!(fixture.config.root.join("bare/refs/NUL").exists());
        }

        #[test]
        fn resolved_git_paths_with_globs_are_literal_and_can_be_outside_root() {
            let mut fixture = Fixture::new("literal-globs");
            let git = fixture.config.root.join("metadata[one]*?");
            let common = fixture.config.root.join("common[one]*?");
            fs::create_dir(&git).unwrap();
            fs::create_dir(&common).unwrap();
            fs::write(git.join("NUL"), b"").unwrap();
            fs::write(common.join("CON"), b"").unwrap();
            let ordinary = fixture.file("metadataoneZZ/NUL", b"");
            fixture.config.git_dir = git;
            fixture.config.common_dir = common;
            assert_eq!(
                inventory(&fixture.config, || {}).unwrap().candidates,
                [ordinary.clone()]
            );
            let outside = fixture.base.join("external-git");
            fs::create_dir(&outside).unwrap();
            fs::write(outside.join("NUL"), b"foreign").unwrap();
            fixture.config.git_dir = outside.clone();
            fixture.config.common_dir = outside.clone();
            // The previous in-root metadata is no longer authoritative and is intentionally
            // ordinary in this synthetic fixture, so it may now be inventoried.
            let output = inventory(&fixture.config, || {}).unwrap();
            assert!(output.candidates.contains(&ordinary));
            assert!(output
                .candidates
                .iter()
                .all(|path| path.starts_with(&fixture.config.root)));
            assert_eq!(fs::read(outside.join("NUL")).unwrap(), b"foreign");
        }

        #[test]
        fn user_symlinks_are_not_followed_but_reserved_links_remain_candidates() {
            let fixture = Fixture::new("symlinks");
            let outside = fixture.base.join("external");
            fs::create_dir(&outside).unwrap();
            fs::write(outside.join("NUL"), b"outside bytes").unwrap();
            symlink(&outside, fixture.config.root.join("external")).unwrap();
            symlink(outside.join("NUL"), fixture.config.root.join("AUX")).unwrap();
            symlink(outside.join("missing"), fixture.config.root.join("PRN")).unwrap();
            let nested = fixture.config.root.join("nested-broken");
            fs::create_dir(&nested).unwrap();
            symlink(outside.join("missing-git"), nested.join(".git")).unwrap();
            fs::write(nested.join("NUL"), b"").unwrap();
            let output = inventory(&fixture.config, || {}).unwrap();
            assert_eq!(
                output.candidates,
                [
                    fixture.config.root.join("AUX"),
                    fixture.config.root.join("PRN")
                ]
            );
            assert!(fs::symlink_metadata(fixture.config.root.join("AUX"))
                .unwrap()
                .file_type()
                .is_symlink());
            assert_eq!(fs::read(outside.join("NUL")).unwrap(), b"outside bytes");
            assert!(output.protected.iter().any(|scope| scope.path == nested));
            assert_eq!(
                directory(
                    &fixture.config.root.join("external"),
                    &fixture.config.root.join("external")
                )
                .unwrap_err()
                .kind,
                ErrorKind::DirectoryChanged
            );
        }

        #[test]
        fn unreadable_owned_directory_fails_with_no_partial_inventory() {
            let fixture = Fixture::new("unreadable-owned");
            fixture.file("NUL", b"");
            let blocked = fixture.config.root.join("blocked");
            fs::create_dir(&blocked).unwrap();
            fs::set_permissions(&blocked, fs::Permissions::from_mode(0o111)).unwrap();
            let denied = fs::read_dir(&blocked).is_err();
            let (result, stdout, stderr) = capture(&fixture.config, || {});
            fs::set_permissions(&blocked, fs::Permissions::from_mode(0o755)).unwrap();
            assert!(
                denied,
                "permission qualification must run as an unprivileged user"
            );
            let error = result.unwrap_err();
            assert_eq!(error.kind, ErrorKind::Enumeration);
            assert_eq!(
                error.source.unwrap().kind(),
                io::ErrorKind::PermissionDenied
            );
            assert!(stdout.is_empty() && stderr.is_empty());
            assert!(fixture.config.root.join("NUL").exists());
        }

        #[test]
        fn unreadable_protected_scopes_are_pruned_before_enumeration() {
            let fixture = Fixture::new("unreadable-protected");
            for path in [
                "worktrees/NUL",
                ".git/NUL",
                "foreign/.git",
                "foreign/NUL",
                "bare/HEAD",
                "bare/objects/NUL",
                "bare/refs/NUL",
            ] {
                fixture.file(path, b"");
            }
            let worktrees = fixture.config.root.join("worktrees");
            let foreign = fixture.config.root.join("foreign");
            let bare = fixture.config.root.join("bare");
            fs::set_permissions(&worktrees, fs::Permissions::from_mode(0)).unwrap();
            fs::set_permissions(&fixture.config.git_dir, fs::Permissions::from_mode(0)).unwrap();
            fs::set_permissions(&foreign, fs::Permissions::from_mode(0o111)).unwrap();
            fs::set_permissions(&bare, fs::Permissions::from_mode(0o111)).unwrap();
            let result = inventory(&fixture.config, || {});
            for path in [&worktrees, &fixture.config.git_dir, &foreign, &bare] {
                fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
            }
            let output = result.unwrap();
            assert!(output.candidates.is_empty());
            assert_eq!(output.protected.len(), 4);
        }

        #[test]
        fn marker_metadata_permission_error_is_propagated_without_candidates() {
            let fixture = Fixture::new("metadata-error");
            fixture.file("NUL", b"");
            let blocked = fixture.config.root.join("blocked");
            fs::create_dir(&blocked).unwrap();
            fs::set_permissions(&blocked, fs::Permissions::from_mode(0)).unwrap();
            let (result, stdout, _) = capture(&fixture.config, || {});
            fs::set_permissions(&blocked, fs::Permissions::from_mode(0o755)).unwrap();
            assert_eq!(result.unwrap_err().kind, ErrorKind::Metadata);
            assert!(stdout.is_empty());
        }

        #[test]
        fn replaced_root_before_publication_fails_without_emitting_collected_paths() {
            let fixture = Fixture::new("root-replaced");
            fixture.file("NUL", b"retained bytes");
            let displaced = fixture.base.join("original-root");
            let (result, stdout, stderr) = capture(&fixture.config, || {
                fs::rename(&fixture.config.root, &displaced).unwrap();
                fs::create_dir(&fixture.config.root).unwrap();
            });
            assert_eq!(result.unwrap_err().kind, ErrorKind::RootChanged);
            assert!(stdout.is_empty() && stderr.is_empty());
            assert_eq!(fs::read(displaced.join("NUL")).unwrap(), b"retained bytes");
        }

        #[test]
        fn root_renamed_or_replaced_by_symlink_never_emits_paths() {
            for link in [false, true] {
                let fixture = Fixture::new("root-renamed");
                fixture.file("NUL", b"");
                let displaced = fixture.base.join("original-root");
                let (result, stdout, _) = capture(&fixture.config, || {
                    fs::rename(&fixture.config.root, &displaced).unwrap();
                    if link {
                        symlink(&displaced, &fixture.config.root).unwrap();
                    }
                });
                assert_eq!(result.unwrap_err().kind, ErrorKind::RootChanged);
                assert!(stdout.is_empty());
                assert!(displaced.join("NUL").exists());
            }
        }

        #[test]
        fn ancestor_symlink_substitution_cannot_reuse_the_same_root_identity() {
            let fixture = Fixture::new("ancestor-symlink");
            fixture.file("NUL", b"retained bytes");
            let displaced = fixture.base.with_extension("original");
            let (result, stdout, _) = capture(&fixture.config, || {
                fs::rename(&fixture.base, &displaced).unwrap();
                symlink(&displaced, &fixture.base).unwrap();
            });
            assert_eq!(result.unwrap_err().kind, ErrorKind::RootChanged);
            assert!(stdout.is_empty());
            assert_eq!(
                fs::read(displaced.join("root/NUL")).unwrap(),
                b"retained bytes"
            );
        }

        #[test]
        fn root_replacement_between_argument_validation_and_scan_is_rejected() {
            let fixture = Fixture::new("root-before-scan");
            fixture.file("NUL", b"retained bytes");
            let displaced = fixture.base.join("original-root");
            fs::rename(&fixture.config.root, &displaced).unwrap();
            fs::create_dir(&fixture.config.root).unwrap();
            let (result, stdout, _) = capture(&fixture.config, || {});
            assert_eq!(result.unwrap_err().kind, ErrorKind::RootChanged);
            assert!(stdout.is_empty());
            assert_eq!(fs::read(displaced.join("NUL")).unwrap(), b"retained bytes");
        }

        #[test]
        fn config_rejects_relative_nonphysical_missing_and_extra_arguments() {
            let fixture = Fixture::new("config");
            let git = fixture.config.git_dir.as_os_str().to_owned();
            assert_eq!(
                Config::from_args([OsString::from("."), git.clone(), git.clone()].into_iter())
                    .unwrap_err()
                    .kind,
                ErrorKind::PathNotPhysical
            );
            let alias = fixture.base.join("root-alias");
            symlink(&fixture.config.root, &alias).unwrap();
            assert_eq!(
                Config::from_args([alias.into_os_string(), git.clone(), git.clone()].into_iter())
                    .unwrap_err()
                    .kind,
                ErrorKind::PathNotPhysical
            );
            assert_eq!(
                Config::from_args(
                    [
                        fixture.base.join("missing").into_os_string(),
                        git.clone(),
                        git.clone()
                    ]
                    .into_iter()
                )
                .unwrap_err()
                .kind,
                ErrorKind::Metadata
            );
            assert_eq!(
                Config::from_args(
                    [
                        fixture.config.root.into_os_string(),
                        git.clone(),
                        git,
                        OsString::from("extra")
                    ]
                    .into_iter()
                )
                .unwrap_err()
                .kind,
                ErrorKind::Usage
            );
        }

        #[test]
        fn reserved_directories_are_candidates_and_their_owned_children_are_scanned() {
            let fixture = Fixture::new("directories");
            let nested = fixture.file("NUL/AUX.txt", b"");
            assert_eq!(
                inventory(&fixture.config, || {}).unwrap().candidates,
                [fixture.config.root.join("NUL"), nested]
            );
        }

        #[test]
        fn output_failure_propagates_typed_error_without_destructive_side_effects() {
            struct BrokenOutput;
            impl Write for BrokenOutput {
                fn write(&mut self, _: &[u8]) -> io::Result<usize> {
                    Err(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "fixture closed output",
                    ))
                }
                fn flush(&mut self) -> io::Result<()> {
                    Ok(())
                }
            }
            let fixture = Fixture::new("broken-output");
            let candidate = fixture.file("NUL", b"retained bytes");
            let output = inventory(&fixture.config, || {}).unwrap();
            assert_eq!(
                emit(&output, &mut BrokenOutput, &mut Vec::new())
                    .unwrap_err()
                    .kind,
                ErrorKind::Output
            );
            assert_eq!(fs::read(candidate).unwrap(), b"retained bytes");
        }
    }
}

#[cfg(all(
    target_os = "linux",
    any(target_arch = "x86_64", target_arch = "aarch64")
))]
fn main() -> std::process::ExitCode {
    use std::io::Write;
    match linux::run(std::env::args_os().skip(1)) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            if writeln!(std::io::stderr().lock(), "{error}").is_err() {
                return std::process::ExitCode::FAILURE;
            }
            std::process::ExitCode::from(if error.kind == linux::ErrorKind::Usage {
                2
            } else {
                1
            })
        }
    }
}

#[cfg(not(all(
    target_os = "linux",
    any(target_arch = "x86_64", target_arch = "aarch64")
)))]
fn main() -> std::process::ExitCode {
    use std::io::Write;
    if writeln!(
        std::io::stderr().lock(),
        "ERROR_UNSUPPORTED: qualified only for Linux x86_64/aarch64 with /proc"
    )
    .is_err()
    {
        return std::process::ExitCode::FAILURE;
    }
    std::process::ExitCode::from(2)
}
