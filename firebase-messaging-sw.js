importScripts("https://www.gstatic.com/firebasejs/10.12.2/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.12.2/firebase-messaging-compat.js");

/* Replace these values after creating the Firebase Web App. */
firebase.initializeApp({
  apiKey: "PASTE_FIREBASE_API_KEY",
  authDomain: "PASTE_FIREBASE_PROJECT_ID.firebaseapp.com",
  projectId: "PASTE_FIREBASE_PROJECT_ID",
  storageBucket: "PASTE_FIREBASE_PROJECT_ID.appspot.com",
  messagingSenderId: "PASTE_FIREBASE_SENDER_ID",
  appId: "PASTE_FIREBASE_APP_ID"
});

const messaging = firebase.messaging();

messaging.onBackgroundMessage((payload) => {
  const title = payload.notification?.title || "Elite FF Tournaments";
  const options = {
    body: payload.notification?.body || "You have a new notification.",
    icon: "/elite-logo.jpg",
    badge: "/elite-logo.jpg",
    data: payload.data || {}
  };
  self.registration.showNotification(title, options);
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = event.notification.data?.url || "/user.html";
  event.waitUntil(clients.openWindow(target));
});
