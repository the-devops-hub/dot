use crate::state::State;
use crate::ui::output;
use clap::Args;

#[derive(Debug, Args)]
pub struct UnpinArgs {
    /// Tool ID to unpin
    pub tool: Option<String>,
}

pub fn run(args: &UnpinArgs, state: &mut State) -> anyhow::Result<()> {
    let id = match &args.tool {
        Some(t) => t.as_str(),
        None => {
            output::print_error("no tool specified — usage: dot unpin <tool>");
            return Ok(());
        }
    };

    if !state.is_installed(id) {
        output::print_error(&format!("'{id}' is not installed"));
        return Ok(());
    }

    if !state.is_pinned(id) {
        eprintln!("  {id} is not pinned");
        return Ok(());
    }

    state.set_pinned(id, false)?;
    state.save()?;
    eprintln!("  Unpinned {id} — it will be upgraded with 'dot upgrade'");
    Ok(())
}
