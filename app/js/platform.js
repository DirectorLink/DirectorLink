// Every browser on iPhone and iPad uses WebKit, which blocks this HTTPS page from calling the
// controller's plain-HTTP address and has no permission to allow it (README): there the app can
// only reach the home through the account (remote.js). iPadOS presents itself as a Mac, but with a
// touch screen.
export function isIOS({ userAgent = "", maxTouchPoints = 0 } = {}) {
  return /iPhone|iPad|iPod/.test(userAgent) || (/Macintosh/.test(userAgent) && maxTouchPoints > 1);
}

export const IS_IOS = isIOS(navigator);
