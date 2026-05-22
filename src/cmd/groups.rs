use crate::tool::{Group, Tool};
use crate::ui::output;
use clap::Args;
use console::style;

#[derive(Debug, Args)]
pub struct GroupsArgs {}

const GROUP_DESCS: &[(Group, &str)] = &[
    (Group::K8s, "Kubernetes ecosystem"),
    (Group::Cloud, "Public cloud CLIs"),
    (Group::Iac, "Infrastructure as Code"),
    (Group::Containers, "Container engines"),
    (Group::Cm, "Configuration management"),
    (Group::Security, "Security scanning & secrets"),
    (Group::Utils, "General-purpose CLI utilities"),
    (Group::Terminal, "Terminal & shell UX"),
];

pub fn run(_args: &GroupsArgs, tools: &[Tool]) -> anyhow::Result<()> {
    output::print_section_header("Groups");

    let colored = output::get_render_mode() == output::RenderMode::Rich;
    if colored {
        eprintln!(
            "\n{:<16} {:<7} Description",
            style("Group").bold(),
            style("Tools").bold()
        );
    } else {
        eprintln!("\n{:<16} {:<7} Description", "Group", "Tools");
    }

    for (group, desc) in GROUP_DESCS {
        let count = tools.iter().filter(|t| t.groups.contains(group)).count();
        eprintln!("{:<16} {:<7} {desc}", group.name(), count);
    }

    eprintln!("\nTip: 'dot list -g <group>'  ·  'dot install -g <group>'\n");
    Ok(())
}
