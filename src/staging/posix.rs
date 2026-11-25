use super::StageError;
use std::{ffi::CStr, mem::MaybeUninit, ops::Range, ptr};

/// Match the caller's character classes without changing any other thread's locale.
pub(super) struct CharacterLocale {
    locale: libc::locale_t,
    previous: libc::locale_t,
}

impl CharacterLocale {
    pub(super) fn activate() -> Result<Self, StageError> {
        // SAFETY: These locale names are terminated and a null base creates a new locale.
        let mut locale =
            unsafe { libc::newlocale(libc::LC_CTYPE_MASK, c"".as_ptr(), ptr::null_mut()) };
        if locale.is_null() {
            locale =
                unsafe { libc::newlocale(libc::LC_CTYPE_MASK, c"C".as_ptr(), ptr::null_mut()) };
        }
        if locale.is_null() {
            return Err(StageError::io(
                "Cannot load character locale",
                std::io::Error::last_os_error(),
            ));
        }

        // SAFETY: The new locale stays alive until the previous thread locale is restored.
        let previous = unsafe { libc::uselocale(locale) };
        if previous.is_null() {
            let error = std::io::Error::last_os_error();
            unsafe { libc::freelocale(locale) };
            return Err(StageError::io("Cannot set thread character locale", error));
        }
        Ok(Self { locale, previous })
    }
}

impl Drop for CharacterLocale {
    fn drop(&mut self) {
        // SAFETY: The previous locale came from this thread and only the new locale is owned.
        unsafe {
            libc::uselocale(self.previous);
            libc::freelocale(self.locale);
        }
    }
}

pub(super) struct Pattern<'locale> {
    regex: libc::regex_t,
    _locale: &'locale CharacterLocale,
}

impl<'locale> Pattern<'locale> {
    pub(super) fn new(
        locale: &'locale CharacterLocale,
        pattern: &CStr,
    ) -> Result<Self, StageError> {
        let mut regex = MaybeUninit::uninit();
        // SAFETY: regcomp initializes the regex on success and the pattern is NUL-terminated.
        let result =
            unsafe { libc::regcomp(regex.as_mut_ptr(), pattern.as_ptr(), libc::REG_EXTENDED) };
        if result != 0 {
            return Err(StageError::validation(format!(
                "Cannot compile metadata pattern {pattern:?} (POSIX regex error {result})"
            )));
        }
        Ok(Self {
            regex: unsafe { regex.assume_init() },
            _locale: locale,
        })
    }

    pub(super) fn find(&self, input: &[u8]) -> Result<Option<Range<usize>>, StageError> {
        let length = libc::regoff_t::try_from(input.len())
            .map_err(|_| StageError::validation("Metadata line is too long"))?;
        let mut found = libc::regmatch_t {
            rm_so: 0,
            rm_eo: length,
        };
        let subject = if input.is_empty() {
            c"".as_ptr()
        } else {
            input.as_ptr().cast()
        };
        // SAFETY: REG_STARTEND bounds the subject by the input slice length.
        // The output slot is writable and the compiled regex is live.
        let result =
            unsafe { libc::regexec(&self.regex, subject, 1, &mut found, libc::REG_STARTEND) };
        match result {
            0 => Ok((found.rm_so >= 0).then_some(found.rm_so as usize..found.rm_eo as usize)),
            libc::REG_NOMATCH => Ok(None),
            _ => Err(StageError::validation(format!(
                "Cannot match metadata (POSIX regex error {result})"
            ))),
        }
    }
}

impl Drop for Pattern<'_> {
    fn drop(&mut self) {
        // SAFETY: Each successfully compiled regex is freed once.
        unsafe { libc::regfree(&mut self.regex) };
    }
}
