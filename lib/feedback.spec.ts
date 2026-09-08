import { beforeEach, describe, expect, it, vi } from 'vitest';
const notification = vi.hoisted(() => vi.fn());
vi.mock('expo-haptics', () => ({ notificationAsync: notification, NotificationFeedbackType: { Success: 'success' } }));
import { notifySuccess } from './feedback';
describe('Optional success feedback', () => {
  beforeEach(() => { notification.mockReset(); });
  it('requests success feedback without returning a blocking promise', () => {
    notification.mockReturnValue(new Promise(() => {}));
    expect(notifySuccess()).toBeUndefined();
    expect(notification).toHaveBeenCalledWith('success');
  });
  it('handles a synchronous native initialization failure', () => {
    notification.mockImplementation(() => { throw new Error('Unsupported'); });
    expect(() => notifySuccess()).not.toThrow();
  });
  it('handles a rejected native request', async () => {
    notification.mockRejectedValue(new Error('Unavailable'));
    notifySuccess();
    await Promise.resolve();
  });
});
