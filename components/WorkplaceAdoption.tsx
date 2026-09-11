import { useEffect, useRef, useState } from 'react';
import { Button, Card, Text } from 'react-native-paper';
import { apiRequest, type ApiProfile, type ApiVenue } from '../lib/api-client';
import { useAuthStore } from '../lib/auth-store';
import { userFromProfile, venueFromAuth } from '../lib/session-from-auth';
import { useI18n } from '../lib/i18n';

type Candidate = { profileId: string; venueName: string; role: string };

export function WorkplaceAdoption() {
  const { t } = useI18n();
  const token = useAuthStore((state) => state.token);
  const verified = useAuthStore((state) => state.user?.email_verified);
  const [candidate, setCandidate] = useState<Candidate | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [reload, setReload] = useState(0);
  const inFlight = useRef(false);
  useEffect(() => {
    let cancelled = false;
    setCandidate(null); setError(null); setLoadFailed(false);
    if (token && verified) {
      void apiRequest<{ pendingAdoption: Candidate | null }>('/v1/auth/pending-adoption')
        .then((result) => { if (!cancelled) setCandidate(result.pendingAdoption); })
        .catch(() => { if (!cancelled) setLoadFailed(true); });
    }
    return () => { cancelled = true; };
  }, [token, verified, reload]);

  const confirm = async () => {
    if (!candidate || !token || inFlight.current) return;
    inFlight.current = true; setBusy(true); setError(null);
    try {
      const result = await apiRequest<{ profile: ApiProfile; venue: ApiVenue | null }>('/v1/auth/confirm-adoption', { method: 'POST', body: { profileId: candidate.profileId } });
      if (useAuthStore.getState().token !== token) return;
      useAuthStore.getState().setSession({ token, user: userFromProfile(result.profile), venue: venueFromAuth(result.profile, result.venue) });
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : t('teamChoice.adoptionConfirmError'));
    } finally { inFlight.current = false; setBusy(false); }
  };

  const visibleError = error || (loadFailed ? t('teamChoice.adoptionLoadError') : null);
  if (!candidate && !visibleError) return null;
  return <Card><Card.Content>
    {candidate && <>
      <Text variant="titleMedium">{t('teamChoice.adoptionTitle', { venueName: candidate.venueName })}</Text>
      <Text>{t('teamChoice.adoptionBody', { role: candidate.role })}</Text>
      <Button mode="contained" loading={busy} disabled={busy} onPress={() => void confirm()}>{t('teamChoice.adoptionConfirm')}</Button>
      <Button disabled={busy} onPress={() => { setCandidate(null); setError(null); }}>{t('teamChoice.adoptionDecline')}</Button>
    </>}
    {visibleError && <><Text accessibilityRole="alert">{visibleError}</Text><Button disabled={busy} onPress={() => setReload((value) => value + 1)}>{t('teamChoice.adoptionRetry')}</Button></>}
  </Card.Content></Card>;
}
