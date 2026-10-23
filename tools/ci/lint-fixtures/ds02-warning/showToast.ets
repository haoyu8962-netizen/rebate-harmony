export function violation(): void {
  const prompt = getUIContext().getPromptAction();
  prompt.showToast({ message: "sample" });
}
