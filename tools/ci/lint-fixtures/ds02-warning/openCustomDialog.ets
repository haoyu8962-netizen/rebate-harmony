export function violation(): void {
  const prompt = getUIContext().getPromptAction();
  prompt.openCustomDialog(new ComponentContent(getUIContext()));
}
