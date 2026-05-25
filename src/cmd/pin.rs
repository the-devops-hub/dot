use crate::state::State;
use crate::ui::output;
use clap::Args;

#[derive(Debug, Args)]
pub struct PinArgs {
    /// Tool ID to pin
    pub tool: Option<String>,
}

pub fn run(args: &PinArgs, state: &mut State) -> anyhow::Result<()> {
    let id = match &args.tool {
        Some(t) => t.as_str(),
        None => {
            output::print_error("no tool specified — usage: dot pin <tool>");
            return Ok(());
        }
    };

    if !state.is_installed(id) {
        output::print_error(&format!("'{id}' is not installed"));
        return Ok(());
    }

    if state.is_pinned(id) {
        eprintln!("  {id} is already pinned");
        return Ok(());
    }

    let version = state.get_version(id).unwrap_or("unknown").to_string();
    state.set_pinned(id, true)?;
    state.save()?;
    eprintln!("  Pinned {id} at {version} — it will not be upgraded automatically");
    Ok(())
}
