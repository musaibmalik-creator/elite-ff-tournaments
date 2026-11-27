importScripts("https://www.gstatic.com/firebasejs/10.12.2/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.12.2/firebase-messaging-compat.js");

/* Replace these values after creating the Firebase Web App. */
firebase.initializeApp({
  apiKey: "AIzaSyDH055Cqyc7dZtyxQ0DHRuXFlS-61FXjN4",
  authDomain: "elite-ff-tournaments01.firebaseapp.com",
  projectId: "elite-ff-tournaments01",
  storageBucket: "elite-ff-tournaments01.firebasestorage.app",
  messagingSenderId: "1024385083938",
  appId: "1:1024385083938:web:76cecdcd53fddc1689387b"
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
