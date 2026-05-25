use assert_cmd::Command;
use predicates::prelude::*;

fn dot() -> Command {
    Command::cargo_bin("dot").unwrap()
}

// ─── help / version ──────────────────────────────────────────────────────────

#[test]
fn help_exits_zero() {
    dot().arg("--help").assert().success();
}

#[test]
fn version_exits_zero() {
    dot().arg("--version").assert().success();
}

#[test]
fn version_contains_semver() {
    dot()
        .arg("--version")
        .assert()
        .success()
        .stdout(predicate::str::is_match(r"\d+\.\d+\.\d+").unwrap());
}

// ─── list ────────────────────────────────────────────────────────────────────

#[test]
fn list_exits_zero() {
    dot().arg("list").assert().success();
}

#[test]
fn list_shows_known_tools() {
    dot()
        .arg("list")
        .assert()
        .success()
        .stderr(predicate::str::contains("kubectl"))
        .stderr(predicate::str::contains("helm"))
        .stderr(predicate::str::contains("terraform"));
}

#[test]
fn list_group_filter_k8s_excludes_terraform() {
    dot()
        .args(["list", "-g", "k8s"])
        .assert()
        .success()
        .stderr(predicate::str::contains("kubectl"))
        .stderr(predicate::str::contains("terraform").not());
}

#[test]
fn list_unknown_group_prints_error() {
    dot()
        .args(["list", "-g", "doesnotexist"])
        .assert()
        .success()
        .stderr(predicate::str::contains("Unknown group"));
}

// ─── groups ──────────────────────────────────────────────────────────────────

#[test]
fn groups_exits_zero() {
    dot().arg("groups").assert().success();
}

#[test]
fn groups_lists_all_categories() {
    dot()
        .arg("groups")
        .assert()
        .success()
        .stderr(predicate::str::contains("k8s"))
        .stderr(predicate::str::contains("security"))
        .stderr(predicate::str::contains("iac"));
}

// ─── search ──────────────────────────────────────────────────────────────────

#[test]
fn search_exits_zero_with_results() {
    dot().args(["search", "helm"]).assert().success();
}

#[test]
fn search_helm_returns_helm() {
    dot()
        .args(["search", "helm"])
        .assert()
        .success()
        .stderr(predicate::str::contains("helm"));
}

#[test]
fn search_k8s_returns_kubectl_and_k9s() {
    dot()
        .args(["search", "k8s"])
        .assert()
        .success()
        .stderr(predicate::str::contains("kubectl"))
        .stderr(predicate::str::contains("k9s"));
}

#[test]
fn search_no_query_prints_error() {
    dot()
        .arg("search")
        .assert()
        .success()
        .stderr(predicate::str::contains("no query"));
}

#[test]
fn search_unknown_term_prints_no_match() {
    dot()
        .args(["search", "xyzzy-no-such-tool-ever"])
        .assert()
        .success()
        .stderr(
            predicate::str::contains("No tools match")
                .or(predicate::str::contains("No exact match")),
        );
}

// ─── info ────────────────────────────────────────────────────────────────────

#[test]
fn info_known_tool_exits_zero() {
    dot().args(["info", "helm"]).assert().success();
}

#[test]
fn info_known_tool_shows_homepage() {
    dot()
        .args(["info", "helm"])
        .assert()
        .success()
        .stderr(predicate::str::contains("helm.sh").or(predicate::str::contains("Homepage")));
}

#[test]
fn info_unknown_tool_shows_error() {
    dot()
        .args(["info", "no-such-tool-xyzzy"])
        .assert()
        .success()
        .stderr(predicate::str::contains("unknown tool"));
}
