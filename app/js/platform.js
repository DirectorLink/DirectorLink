// Every browser on iPhone and iPad uses WebKit, which blocks this HTTPS page from calling the
// controller's plain-HTTP address and has no permission to allow it (README): there the app can
// only reach the home through the account (remote.js). iPadOS presents itself as a Mac, but with a
// touch screen.
export const IS_IOS =
  /iPhone|iPad|iPod/.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);
