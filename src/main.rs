mod archive;
mod cli;
mod cmd;
mod error;
mod http;
mod install;
mod paths;
mod platform;
mod repository;
mod shell;
mod state;
mod template;
mod tool;
mod ui;
mod util;
mod validate;

use clap::Parser;
use cli::{Cli, Commands};
use ui::output;

fn main() {
    output::init_caps();

    let cli = Cli::parse();

    if let Err(e) = run(cli) {
        output::print_error(&format!("{e:#}"));
        std::process::exit(1);
    }
}

fn run(cli: Cli) -> anyhow::Result<()> {
    let Some(command) = cli.command else {
        // Print help when invoked with no subcommand
        use clap::CommandFactory;
        Cli::command().print_help()?;
        return Ok(());
    };

    // Commands that only need state (no tool list required)
    match &command {
        Commands::Pin(args) => {
            let mut state = state::State::load_default()?;
            return cmd::pin::run(args, &mut state);
        }
        Commands::Unpin(args) => {
            let mut state = state::State::load_default()?;
            return cmd::unpin::run(args, &mut state);
        }
        Commands::Update(args) => {
            let mut state = state::State::load_default()?;
            return cmd::update::run(args, &mut state);
        }
        _ => {}
    }

    // Commands that need the merged tool list
    let tools = repository::load_all_tools()?;

    match command {
        Commands::Groups(args) => cmd::groups::run(&args, &tools),
        Commands::Search(args) => cmd::search::run(&args, &tools),
        Commands::List(args) => {
            let state = state::State::load_default()?;
            cmd::list::run(&args, &state, &tools)
        }
        Commands::Info(args) => {
            let state = state::State::load_default()?;
            cmd::info::run(&args, &state, &tools)
        }
        Commands::Doctor(args) => {
            let state = state::State::load_default()?;
            cmd::doctor::run(&args, &state, &tools)
        }
        Commands::Outdated(args) => {
            let state = state::State::load_default()?;
            cmd::outdated::run(&args, &state, &tools)
        }
        Commands::Install(args) => {
            let mut state = state::State::load_default()?;
            cmd::install::run(&args, &mut state, &tools)
        }
        Commands::Upgrade(args) => {
            let mut state = state::State::load_default()?;
            cmd::upgrade::run(&args, &mut state, &tools)
        }
        Commands::Uninstall(args) => {
            let mut state = state::State::load_default()?;
            cmd::uninstall::run(&args, &mut state, &tools)
        }
        // Already handled above
        Commands::Pin(_) | Commands::Unpin(_) | Commands::Update(_) => unreachable!(),
    }
}
