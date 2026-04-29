export function hostnameFromUrl(value: string | undefined, fallback = "Local") {
  if (!value) return fallback;

  try {
    return new URL(value).hostname;
  } catch {
    return fallback;
  }
}
