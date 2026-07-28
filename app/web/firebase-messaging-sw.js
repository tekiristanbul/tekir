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
  apiKey: 'AIzaSyCLXKND6OkamSuHO_98kprJjM08lxqtTtc',
  authDomain: 'tekir-28c02.firebaseapp.com',
  projectId: 'tekir-28c02',
  storageBucket: 'tekir-28c02.firebasestorage.app',
  messagingSenderId: '643225965073',
  appId: '1:643225965073:web:7a3cf7e52398095b2c17b0',
});

/*
 * registering the messaging instance is all that's needed: the backend
 * always sends a notification payload (title/body composed server-side —
 * see backend FCMNotificationSender), so the browser displays it natively
 * in the background; no custom onBackgroundMessage handler or local
 * notification composition happens here.
 */
firebase.messaging();
