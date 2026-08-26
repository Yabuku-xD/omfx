const panel_mod = @import("panel.zig");
const cmds = @import("cmds.zig");

const session_mod = @import("repl/session.zig");
const settings_mod = @import("panels/settings.zig");
const browse_mod = @import("panels/browse.zig");

const Session = session_mod.Session;

pub const max_editors = settings_mod.max_editors;
pub const detectEditors = settings_mod.detectEditors;
pub const settingsPanel = settings_mod.settingsPanel;
pub const applyPanelField = settings_mod.applyPanelField;
pub const togglePanelField = settings_mod.togglePanelField;
pub const stepPanelValue = settings_mod.stepPanelValue;
pub const editDraftExternally = settings_mod.editDraftExternally;
pub const statuslinePanel = settings_mod.statuslinePanel;
pub const fieldHelp = settings_mod.fieldHelp;

pub const statusPanel = browse_mod.statusPanel;
pub const jobsPanel = browse_mod.jobsPanel;
pub const planPanel = browse_mod.planPanel;
pub const filesPanel = browse_mod.filesPanel;
pub const peersPanel = browse_mod.peersPanel;
pub const workspacePanel = browse_mod.workspacePanel;
pub const keysPanel = browse_mod.keysPanel;
pub const keyMatches = browse_mod.keyMatches;
pub const lessThanSpec = browse_mod.lessThanSpec;
pub const helpPanel = browse_mod.helpPanel;
pub const commandMatches = browse_mod.commandMatches;
pub const contextPanel = browse_mod.contextPanel;
pub const usagePanel = browse_mod.usagePanel;
pub const usagePanelFrom = browse_mod.usagePanelFrom;
pub const UsageView = browse_mod.UsageView;
pub const addCacheRows = browse_mod.addCacheRows;
pub const contextRow = browse_mod.contextRow;
pub const rewindPanel = browse_mod.rewindPanel;
pub const sessionPanel = browse_mod.sessionPanel;

pub fn build(sess: *Session, kind: cmds.PanelKind) panel_mod.Panel {
    return switch (kind) {
        .settings => settings_mod.settingsPanel(sess),
        .help => browse_mod.helpPanel(sess),
        .shortcuts => browse_mod.keysPanel(sess),
        .sessions => browse_mod.sessionPanel(sess),
        .statusline => settings_mod.statuslinePanel(sess),
        .status => browse_mod.statusPanel(sess),
        .rewind => browse_mod.rewindPanel(sess),
        .context, .usage => browse_mod.usagePanel(sess),
        .jobs => browse_mod.jobsPanel(sess),
        .workspace => browse_mod.workspacePanel(sess),
        .plan => browse_mod.planPanel(sess),
        .files => browse_mod.filesPanel(sess),
        .peers => browse_mod.peersPanel(sess),
    };
}
