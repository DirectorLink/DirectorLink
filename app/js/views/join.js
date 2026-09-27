// #/join: accepting an invitation (docs/ACCOUNTS.md). The link's secret was taken out of the
// address as the page opened (app.js) and is kept for this tab only, so it survives the Google
// sign-in but is never sent to a server or left in the history.

import { saveApiKey } from "../../api-client.js";
import { signIn } from "../account.js";
import { h } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { RemoteError, acceptInvitation, parseInvitation, saveRemote } from "../remote.js";
import { clientName, connect, errorText } from "../session.js";
import { notify, state, ui } from "../state.js";
import { pageHeader } from "./common.js";

const JOIN_KEY = "directorlink.join";

export function storeInvitation(text) {
  try {
    sessionStorage.setItem(JOIN_KEY, text);
  } catch {
    // Blocked storage: the invitation cannot outlive this page.
  }
}

function storedInvitation() {
  try {
    return parseInvitation(sessionStorage.getItem(JOIN_KEY));
  } catch {
    return null;
  }
}

function clearInvitation() {
  try {
    sessionStorage.removeItem(JOIN_KEY);
  } catch {
    // Nothing stored.
  }
}

function joinError(error) {
  if (error instanceof RemoteError) {
    switch (error.code) {
      case "EMAIL_MISMATCH":
        return t("join.errors.emailMismatch");
      case "INVITATION_NOT_FOUND":
      case "JOIN_REFUSED":
        return t("join.errors.used");
      case "HOME_OFFLINE":
      case "HOME_TIMEOUT":
        return t("join.errors.homeOffline");
      case "NOT_SIGNED_IN":
        return t("join.errors.signIn");
      default:
        break;
    }
  }
  return errorText(error);
}

async function accept(invitation, navigate) {
  ui.joinBusy = true;
  ui.joinMessage = null;
  notify();
  try {
    const key = await acceptInvitation(invitation, clientName());
    saveApiKey(key.key);
    saveRemote({ home: invitation.home, keyId: key.id });
    state.apiKey = key.key;
    state.transport = "remote";
    state.status = "connecting";
    clearInvitation();
    navigate("#/");
    connect();
  } catch (error) {
    ui.joinMessage = joinError(error);
  } finally {
    ui.joinBusy = false;
    notify();
  }
}

export function joinView({ navigate }) {
  const invitation = storedInvitation();
  const account = state.account;
  const content = [];
  if (!invitation) {
    content.push(h("p", { class: "connect-text" }, t("join.missing")));
  } else if (account.status === "unknown" || account.status === "loading") {
    content.push(h("p", { class: "field-help", role: "status" }, t("common.loading")));
  } else if (account.status !== "signed-in") {
    content.push(
      h("p", { class: "connect-text" }, t("join.intro")),
      h("p", { class: "field-help" }, t("join.signInFirst")),
      h("button", { type: "button", class: "button button-primary button-wide", dataset: { key: "join-sign-in" }, onclick: () => signIn("#/join") }, icon("user"), t("connect.signIn"))
    );
  } else {
    content.push(
      h("p", { class: "connect-text" }, t("join.intro")),
      h("p", { class: "connect-signed-in" }, icon("user"), t("join.as", { email: account.user.email })),
      ui.joinMessage ? h("p", { class: "notice notice-error", role: "alert" }, ui.joinMessage) : null,
      h(
        "button",
        { type: "button", class: "button button-primary button-wide", dataset: { key: "join-accept" }, disabled: Boolean(ui.joinBusy), onclick: () => accept(invitation, navigate) },
        ui.joinBusy ? t("join.accepting") : t("join.accept")
      )
    );
  }
  return [
    pageHeader({ title: t("join.title") }),
    h(
      "div",
      { class: "connect" },
      h(
        "section",
        { class: "card connect-card", "aria-labelledby": "join-title" },
        h("span", { class: "connect-icon" }, icon("key")),
        h("h2", { id: "join-title", class: "connect-title" }, t("join.heading")),
        ...content
      )
    ),
  ];
}
