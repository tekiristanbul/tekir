/*
 * firebase messaging service worker (issue #84) — required only for
 * background/terminated push on the *web* target. foreground web push and
 * all non-web targets work without this file.
 *
 * the values below are the firebase *public client configuration* (the
 * same values flutterfire configure writes into lib/firebase_options.dart
 * for the web app) — they are not secrets, but the placeholders must be
 * replaced with the real project's values before web background push can
 * work. keep the firebase sdk version aligned with the firebase_core
 * pubspec dependency's bundled web sdk.
 */

importScripts(
  'https://www.gstatic.com/firebasejs/11.6.0/firebase-app-compat.js'
);
importScripts(
  'https://www.gstatic.com/firebasejs/11.6.0/firebase-messaging-compat.js'
);

firebase.initializeApp({
  apiKey: '__FIREBASE_WEB_API_KEY__',
  authDomain: '__FIREBASE_AUTH_DOMAIN__',
  projectId: '__FIREBASE_PROJECT_ID__',
  storageBucket: '__FIREBASE_STORAGE_BUCKET__',
  messagingSenderId: '__FIREBASE_MESSAGING_SENDER_ID__',
  appId: '__FIREBASE_WEB_APP_ID__',
});

/*
 * registering the messaging instance is all that's needed: the backend
 * always sends a notification payload (title/body composed server-side —
 * see backend FCMNotificationSender), so the browser displays it natively
 * in the background; no custom onBackgroundMessage handler or local
 * notification composition happens here.
 */
firebase.messaging();
