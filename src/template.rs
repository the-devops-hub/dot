use crate::error::DotError;
use crate::platform::{Arch, OperatingSystem};

pub struct TemplateContext<'a> {
    pub version: &'a str,
    pub os: OperatingSystem,
    pub arch: Arch,
    pub bin_dir: &'a str,
    pub opt_dir: &'a str,
}

/// Replace `{key}` placeholders in `tmpl` with context values.
pub fn render(tmpl: &str, ctx: &TemplateContext<'_>) -> Result<String, DotError> {
    let mut out = String::with_capacity(tmpl.len() + 16);
    let mut rest = tmpl;
    while !rest.is_empty() {
        if let Some(brace) = rest.find('{') {
            out.push_str(&rest[..brace]);
            rest = &rest[brace..];
            if let Some(close) = rest.find('}') {
                let key = &rest[1..close];
                let replacement = match key {
                    "version" => ctx.version,
                    "os" => ctx.os.name(),
                    "arch" => ctx.arch.go_name(),
                    "arch_uname" => ctx.arch.uname_name(),
                    "arch_alt" => ctx.arch.alt_name(),
                    "os_title" => ctx.os.title_name(),
                    "os_zig" => ctx.os.zig_name(),
                    "rust_target" => ctx.arch.rust_target(ctx.os),
                    "bin_dir" => ctx.bin_dir,
                    "opt_dir" => ctx.opt_dir,
                    _ => {
                        out.push_str(&rest[..close + 1]);
                        rest = &rest[close + 1..];
                        continue;
                    }
                };
                out.push_str(replacement);
                rest = &rest[close + 1..];
            } else {
                out.push('{');
                rest = &rest[1..];
            }
        } else {
            out.push_str(rest);
            break;
        }
    }
    Ok(out)
}

/// Convert a GitHub tag to a clean version string.
/// Strips a leading 'v', then strips `strip_prefix` if provided.
pub fn tag_to_version<'a>(tag: &'a str, strip_prefix: Option<&str>) -> &'a str {
    let mut ver = tag;
    if ver.starts_with('v') {
        ver = &ver[1..];
    }
    if let Some(pfx) = strip_prefix {
        if ver.starts_with(pfx) {
            ver = &ver[pfx.len()..];
        }
    }
    ver
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx(version: &str) -> TemplateContext<'_> {
        TemplateContext {
            version,
            os: OperatingSystem::Linux,
            arch: Arch::X86_64,
            bin_dir: "/home/user/.local/bin",
            opt_dir: "/home/user/.local/opt/helm",
        }
    }

    #[test]
    fn render_basic_placeholders() {
        let c = ctx("3.15.0");
        let result = render("helm-v{version}-{os}-{arch}.tar.gz", &c).unwrap();
        assert_eq!(result, "helm-v3.15.0-linux-amd64.tar.gz");
    }

    #[test]
    fn render_arch_uname() {
        let c = ctx("1.0");
        assert_eq!(render("{arch_uname}", &c).unwrap(), "x86_64");
    }

    #[test]
    fn render_arch_alt() {
        let c = ctx("1.0");
        assert_eq!(render("{arch_alt}", &c).unwrap(), "x86_64");
    }

    #[test]
    fn render_os_title() {
        let c = ctx("1.0");
        assert_eq!(render("{os_title}", &c).unwrap(), "Linux");
    }

    #[test]
    fn render_os_zig() {
        let c = ctx("1.0");
        assert_eq!(render("{os_zig}", &c).unwrap(), "linux");
    }

    #[test]
    fn render_rust_target() {
        let c = ctx("1.0");
        assert_eq!(
            render("{rust_target}", &c).unwrap(),
            "x86_64-unknown-linux-gnu"
        );
    }

    #[test]
    fn render_bin_dir() {
        let c = ctx("1.0");
        assert_eq!(render("{bin_dir}", &c).unwrap(), "/home/user/.local/bin");
    }

    #[test]
    fn render_opt_dir() {
        let c = ctx("1.0");
        assert_eq!(
            render("{opt_dir}", &c).unwrap(),
            "/home/user/.local/opt/helm"
        );
    }

    #[test]
    fn render_unknown_placeholder_passthrough() {
        let c = ctx("1.0");
        assert_eq!(render("{unknown_key}", &c).unwrap(), "{unknown_key}");
    }

    #[test]
    fn render_no_placeholders() {
        let c = ctx("1.0");
        assert_eq!(render("plain-string", &c).unwrap(), "plain-string");
    }

    #[test]
    fn tag_to_version_strips_v() {
        assert_eq!(tag_to_version("v3.15.0", None), "3.15.0");
    }

    #[test]
    fn tag_to_version_no_v_unchanged() {
        assert_eq!(tag_to_version("3.15.0", None), "3.15.0");
    }

    #[test]
    fn tag_to_version_strip_prefix() {
        assert_eq!(tag_to_version("jq-1.8.1", Some("jq-")), "1.8.1");
    }

    #[test]
    fn tag_to_version_strip_prefix_not_present() {
        assert_eq!(tag_to_version("1.8.1", Some("jq-")), "1.8.1");
    }

    #[test]
    fn tag_to_version_v_before_strip_prefix() {
        assert_eq!(tag_to_version("vjq-1.0", Some("jq-")), "1.0");
    }

    #[test]
    fn tag_to_version_empty() {
        assert_eq!(tag_to_version("", None), "");
        assert_eq!(tag_to_version("", Some("jq-")), "");
    }
}
