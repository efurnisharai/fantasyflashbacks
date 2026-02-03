import { Capacitor } from '@capacitor/core';
import { Haptics, ImpactStyle } from '@capacitor/haptics';
import { Share } from '@capacitor/share';
import { PushNotifications } from '@capacitor/push-notifications';

// Check if running in native app
export const isNative = Capacitor.isNativePlatform();

// ============ HAPTICS ============

export const hapticLight = async () => {
  if (!isNative) return;
  try {
    await Haptics.impact({ style: ImpactStyle.Light });
  } catch (e) {
    console.warn('Haptics not available:', e);
  }
};

export const hapticMedium = async () => {
  if (!isNative) return;
  try {
    await Haptics.impact({ style: ImpactStyle.Medium });
  } catch (e) {
    console.warn('Haptics not available:', e);
  }
};

export const hapticHeavy = async () => {
  if (!isNative) return;
  try {
    await Haptics.impact({ style: ImpactStyle.Heavy });
  } catch (e) {
    console.warn('Haptics not available:', e);
  }
};

export const hapticSuccess = async () => {
  if (!isNative) return;
  try {
    await Haptics.notification({ type: 'success' });
  } catch (e) {
    console.warn('Haptics not available:', e);
  }
};

export const hapticWarning = async () => {
  if (!isNative) return;
  try {
    await Haptics.notification({ type: 'warning' });
  } catch (e) {
    console.warn('Haptics not available:', e);
  }
};

export const hapticError = async () => {
  if (!isNative) return;
  try {
    await Haptics.notification({ type: 'error' });
  } catch (e) {
    console.warn('Haptics not available:', e);
  }
};

// ============ SHARE ============

export const shareInvite = async (roomCode) => {
  const shareData = {
    title: 'Fantasy Flashback',
    text: `Join my Fantasy Flashback draft! Room code: ${roomCode}`,
    url: `https://fantasyflashbacks.com/?room=${roomCode}`,
    dialogTitle: 'Invite a friend',
  };

  if (isNative) {
    try {
      await Share.share(shareData);
      return true;
    } catch (e) {
      console.warn('Share failed:', e);
      return false;
    }
  } else {
    // Fallback to Web Share API or clipboard
    if (navigator.share) {
      try {
        await navigator.share(shareData);
        return true;
      } catch (e) {
        return false;
      }
    }
    return false;
  }
};

// ============ PUSH NOTIFICATIONS ============

let pushToken = null;

export const initPushNotifications = async (onNotification) => {
  if (!isNative) return null;

  try {
    // Request permission
    const permStatus = await PushNotifications.requestPermissions();

    if (permStatus.receive !== 'granted') {
      console.log('Push notification permission not granted');
      return null;
    }

    // Register with APNs/FCM
    await PushNotifications.register();

    // Listen for registration success
    PushNotifications.addListener('registration', (token) => {
      console.log('Push registration success:', token.value);
      pushToken = token.value;
    });

    // Listen for registration errors
    PushNotifications.addListener('registrationError', (error) => {
      console.error('Push registration error:', error);
    });

    // Listen for notifications received while app is open
    PushNotifications.addListener('pushNotificationReceived', (notification) => {
      console.log('Push notification received:', notification);
      if (onNotification) {
        onNotification(notification);
      }
    });

    // Listen for notification taps
    PushNotifications.addListener('pushNotificationActionPerformed', (action) => {
      console.log('Push notification action:', action);
      if (onNotification) {
        onNotification(action.notification, true);
      }
    });

    return pushToken;
  } catch (e) {
    console.warn('Push notifications not available:', e);
    return null;
  }
};

export const getPushToken = () => pushToken;
