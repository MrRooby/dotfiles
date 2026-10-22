// lets chrome/userChrome.css load (nostromo Firefox styling)
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
user_pref("middlemouse.paste", false);

// page scrollbars: grey thumb at rest (on dark pages the GTK one came out
// nearly black on black), nostromo orange on hover / drag. Prefs rather
// than userContent.css: a CSS scrollbar-color throws away the hover colours.
user_pref("ui.themedScrollbar", "#11111b");
user_pref("ui.themedScrollbarThumb", "#9b9b9b");
user_pref("ui.themedScrollbarThumbHover", "#CE6B29");
user_pref("ui.themedScrollbarThumbActive", "#CE6B29");
