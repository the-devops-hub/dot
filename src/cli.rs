use crate::cmd;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "dot", version, about = "Manage DevOps tools")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Commands>,
}

#[derive(Subcommand)]
pub enum Commands {
    /// Install a tool or group
    Install(cmd::install::InstallArgs),
    /// Upgrade installed tools
    Upgrade(cmd::upgrade::UpgradeArgs),
    /// Uninstall a tool
    #[command(alias = "remove")]
    Uninstall(cmd::uninstall::UninstallArgs),
    /// List tools
    List(cmd::list::ListArgs),
    /// Search available tools
    Search(cmd::search::SearchArgs),
    /// Show detailed info about a tool
    Info(cmd::info::InfoArgs),
    /// List tool groups
    Groups(cmd::groups::GroupsArgs),
    /// Run a system health check
    Doctor(cmd::doctor::DoctorArgs),
    /// Pin a tool at its current version
    Pin(cmd::pin::PinArgs),
    /// Unpin a tool
    Unpin(cmd::unpin::UnpinArgs),
    /// List installed tools with newer versions available
    Outdated(cmd::outdated::OutdatedArgs),
    /// Update dot itself
    Update(cmd::update::UpdateArgs),
}
