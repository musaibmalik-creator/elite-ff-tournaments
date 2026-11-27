# Elite FF Notifications Setup

The notification feature is prepared in this repository. It needs one-time Firebase and Supabase configuration before phone push notifications can work.

## 1. Firebase Web App

1. Open https://console.firebase.google.com/ and create/select a Firebase project.
2. Add a Web App (</>) to that project.
3. Copy the Firebase web config values into the `FIREBASE_CONFIG` object in `user.html`.
4. Copy the same values into `firebase.initializeApp({...})` in the root `firebase-messaging-sw.js`.
5. In Firebase Console > Project Settings > Cloud Messaging > Web Push certificates, generate a key pair. Put the public key into `FIREBASE_VAPID_KEY` in `user.html`.
6. Ensure Firebase Cloud Messaging API (HTTP v1) is enabled for the project.

## 2. Supabase database

Run the complete SQL in `supabase/notifications.sql` once in Supabase SQL Editor.

## 3. Supabase Edge Function

Deploy `supabase/functions/send-notification/index.ts` as an Edge Function named `send-notification`.

In Supabase Dashboard > Edge Functions > Secrets, add:

- Name: `FIREBASE_SERVICE_ACCOUNT`
- Value: the complete JSON contents of the Firebase service-account private-key file downloaded from Firebase Project Settings > Service accounts.

Do not put the service-account JSON, private key, or Supabase service-role key in either HTML file or GitHub.

Supabase provides `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions automatically.

## 4. Test

1. Wait for Vercel to deploy the latest GitHub commit.
2. Open the player app, sign in, and tap **ENABLE NOTIFICATIONS**. Allow notifications.
3. Repeat on each phone/account that should receive push notifications.
4. From Admin > Send User Notification, send a test announcement.
5. Join a test tournament with a player account, then add/change its Room ID or Password from Admin. Only players registered in that tournament should receive the room-release notification.

The notification itself never contains the Room ID or Password. It only says the details are ready; the player must sign in and open the tournament dashboard. Existing room-detail access checks in the player app remain responsible for displaying the credentials.

## Important device note

Push can arrive while the screen is off if the phone is powered on, connected to the internet, and Android/browser notifications are allowed. It cannot arrive while the phone is completely powered off. Battery optimization, data saver, browser restrictions, or revoked notification permission may delay/block delivery.
