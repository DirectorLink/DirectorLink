// https://github.directorlink.io: the project's short link to its source code on GitHub.
// Every path and query goes on to the same place in the repository, so /releases/latest,
// /issues, /blob/main/docs/... and `git clone https://github.directorlink.io` all work.
const REPOSITORY = "https://github.com/IsraelCIL/DirectorLink";

export default {
  fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname === "/" ? "" : url.pathname;
    return Response.redirect(REPOSITORY + path + url.search, 301);
  },
};
