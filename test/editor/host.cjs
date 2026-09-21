const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const vscode = require('vscode');

exports.run = async function run() {
  const report = { version: vscode.version, checks: [] };
  try {
    const theme = vscode.workspace.getConfiguration('workbench').get('colorTheme');
    assert(vscode.extensions.getExtension('foo.foo'), 'FOO extension not registered');
    const document = await vscode.workspace.openTextDocument(path.resolve(__dirname, 'cases/pointers.iv'));
    assert.equal(document.languageId, 'foo', '.iv must select FOO without file associations');
    assert.equal(vscode.workspace.getConfiguration('editor', document).get('bracketPairColorization.enabled'), true);
    report.checks.push('clean .iv detection', 'language defaults');
    const scratch = await vscode.workspace.openTextDocument({ language: 'foo', content: 'constant value is 1.' });
    const editor = await vscode.window.showTextDocument(scratch);
    editor.options = { insertSpaces: true, tabSize: 2 };
    async function replace(text) {
      await editor.edit(edit => edit.replace(new vscode.Range(scratch.positionAt(0), scratch.positionAt(scratch.getText().length)), text));
      editor.selection = new vscode.Selection(0, 0, 0, 0);
    }
    await vscode.commands.executeCommand('editor.action.commentLine');
    assert.match(scratch.getText(), /^--\s*constant/);
    await vscode.commands.executeCommand('editor.action.commentLine');
    assert.equal(scratch.getText(), 'constant value is 1.');
    report.checks.push('line comment toggle');
    editor.selection = new vscode.Selection(scratch.positionAt(0), scratch.positionAt(scratch.getText().length));
    await vscode.commands.executeCommand('editor.action.blockComment');
    assert.match(scratch.getText(), /^---[\s\S]*---$/);
    await vscode.commands.executeCommand('editor.action.blockComment');
    assert.equal(scratch.getText(), 'constant value is 1.');
    report.checks.push('block comment toggle');
    for (const [open, close] of [['(', ')'], ['[', ']'], ['{', '}'], ['"', '"'], ["'", "'"]]) {
      await replace('');
      await vscode.commands.executeCommand('type', { text: open });
      assert.equal(scratch.getText(), open + close, `Auto-close ${open}`);
    }
    report.checks.push('five auto-close pairs');
    await replace('value');
    editor.selection = new vscode.Selection(0, 0, 0, 5);
    await vscode.commands.executeCommand('type', { text: '(' });
    assert.equal(scratch.getText(), '(value)');
    report.checks.push('selection surrounding');
    await replace('module sample ');
    editor.selection = new vscode.Selection(0, 14, 0, 14);
    await vscode.commands.executeCommand('type', { text: '{' });
    await vscode.commands.executeCommand('type', { text: '\n' });
    assert.equal(scratch.lineAt(1).text, '  ', 'Opening block must indent');
    assert.equal(scratch.lineAt(2).text, '}', 'Closing brace must dedent');
    report.checks.push('block indentation and dedentation');
    editor.selection = new vscode.Selection(0, 14, 0, 14);
    await vscode.commands.executeCommand('editor.action.jumpToBracket');
    assert.equal(editor.selection.active.line, 2);
    report.checks.push('bracket matching');
    const pointer = document.positionAt(document.getText().indexOf('data of type pointer'));
    const word = document.getWordRangeAtPosition(pointer.translate(0, 1));
    assert(word && document.getText(word) === 'data');
    report.checks.push('identifier word selection');
    await vscode.commands.executeCommand('workbench.action.revertAndCloseActiveEditor');
    const display = await vscode.window.showTextDocument(document);
    display.selection = new vscode.Selection(pointer.translate(0, 20), pointer.translate(0, 20));
    await vscode.commands.executeCommand('editor.action.inspectTMScopes');
    report.checks.push('token inspector');
    await vscode.commands.executeCommand('workbench.view.explorer');
    await vscode.commands.executeCommand('revealInExplorer', document.uri);
    await vscode.window.showTextDocument(document);
    const commands = await vscode.commands.getCommands(true);
    if (commands.includes('workbench.action.closeAuxiliaryBar')) await vscode.commands.executeCommand('workbench.action.closeAuxiliaryBar');
    display.selection = new vscode.Selection(0, 0, 0, 0);
    assert.equal(vscode.workspace.getConfiguration('workbench').get('colorTheme'), theme, 'FOO must preserve the selected theme');
    assert(!vscode.extensions.getExtension('foo.foo').packageJSON.contributes.themes, 'FOO must not install a theme');
    assert.deepEqual(vscode.workspace.getConfiguration('workbench').get('colorCustomizations'), {}, 'FOO must not override interface colors');
    report.checks.push('selected theme and interface colors preserved');
    report.success = true;
  } catch (error) {
    report.success = false;
    report.error = error.stack || String(error);
    throw error;
  } finally {
    if (process.env.FOO_REPORT) fs.writeFileSync(process.env.FOO_REPORT, JSON.stringify(report, null, 2));
    if (report.success && process.env.FOO_RELEASE) {
      const deadline = Date.now() + 30000;
      while (!fs.existsSync(process.env.FOO_RELEASE) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 100));
    }
  }
};
