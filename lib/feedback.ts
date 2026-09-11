import * as Haptics from 'expo-haptics';

/** Optional device feedback must never delay or undo a successful operation. */
export function notifySuccess(): void {
  try {
    void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => undefined);
  } catch {
    // Some devices/platforms cannot initialize haptics at all.
  }
}
