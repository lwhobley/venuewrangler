import { Button } from '../components/AppButton';
import { useMemo, useRef, useState } from 'react';
import { View } from 'react-native';
import { FormScreen } from '../components/FormScreen';
import { router } from 'expo-router';
import { Chip, IconButton, Text, TextInput as PaperTextInput } from 'react-native-paper';
import { useMutation, useQuery } from '../lib/railway-hooks';
import { api } from '../lib/railway-api';
import { colors, spacing, type } from '../lib/theme';
import { AppCard } from '../components/AppCard';
import { ScreenErrorBoundary } from '../components/ErrorBoundary';
import { errorMessage } from '../lib/format';
import { useVenueAuth } from '../lib/useVenueAuth';
import { useI18n } from '../lib/i18n';

type LogbookEntry = {
  _id: string;
  authorProfileId: string;
  authorName: string;
  category: string;
  body: string;
  pinned: boolean;
  createdAt: number;
};

function formatTimestamp(ms: number): string {
  const date = new Date(ms);
  return `${date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })} · ${date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })}`;
}

function LogbookScreen() {
  const { t } = useI18n();
  const { venue, isReady, canManage, me } = useVenueAuth();
  const CATEGORIES: Array<{ value: string; label: string }> = [
    { value: 'handoff', label: t('logbook.categoryHandoff') },
    { value: 'incident', label: t('logbook.categoryIncident') },
    { value: 'maintenance', label: t('logbook.categoryMaintenance') },
    { value: 'general', label: t('logbook.categoryGeneral') },
  ];
  const myProfileId = me?.profile._id ?? null;
  const entriesQuery = useQuery(api.operations.listLogbook, isReady && venue?.id ? { limit: 100 } : 'skip') as { entries: LogbookEntry[] } | null | undefined;
  const entries = useMemo(() => entriesQuery?.entries ?? [], [entriesQuery]);

  const addEntry = useMutation(api.operations.addLogbookEntry);
  const deleteEntry = useMutation(api.operations.deleteLogbookEntry);

  const [category, setCategory] = useState('handoff');
  const [body, setBody] = useState('');
  const [pinned, setPinned] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const busyRef = useRef(false);

  const onPost = async () => {
    if (busyRef.current || !body.trim()) return;
    busyRef.current = true;
    setBusy(true);
    setError(null);
    try {
      await addEntry({ category, body: body.trim(), pinned });
      setBody('');
      setPinned(false);
    } catch (e) {
      setError(errorMessage(e, t('logbook.errorPost')));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  };

  const onDelete = async (id: string) => {
    try {
      await deleteEntry(id);
    } catch (e) {
      setError(errorMessage(e, t('logbook.errorRemove')));
    }
  };

  return (
    <FormScreen contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xxl }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
        <IconButton icon="arrow-left" onPress={() => router.back()} />
        <View style={{ flex: 1 }}>
          <Text style={{ ...type.title, color: colors.charcoal }}>{t('logbook.title')}</Text>
          <Text style={{ color: colors.muted }}>{t('logbook.subtitle')}</Text>
        </View>
      </View>

      <AppCard>
          <View style={{ gap: spacing.sm }}>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
            {CATEGORIES.map((c) => (
              <Chip key={c.value} selected={category === c.value} onPress={() => setCategory(c.value)}>{c.label}</Chip>
            ))}
          </View>
          <PaperTextInput
            placeholder={t('logbook.bodyPlaceholder')}
            value={body}
            onChangeText={setBody}
            mode="outlined"
            multiline
            numberOfLines={4}
            style={{ backgroundColor: colors.surface, minHeight: 90 }}
          />
          {canManage ? (
            <Chip selected={pinned} onPress={() => setPinned((v) => !v)} icon="pin">
              {t('logbook.pinToTop')}
            </Chip>
          ) : null}
          <Button mode="contained" buttonColor={colors.primary} loading={busy} disabled={busy || !body.trim()} onPress={() => void onPost()}>
            {t('logbook.postEntry')}
          </Button>
          {error ? <Text style={{ color: colors.danger }}>{error}</Text> : null}
          </View>
      </AppCard>

      {entries.length === 0 ? (
        <Text style={{ color: colors.muted, textAlign: 'center', marginTop: spacing.lg }}>{t('logbook.noEntries')}</Text>
      ) : (
        entries.map((entry) => {
          const categoryLabel = CATEGORIES.find((c) => c.value === entry.category)?.label ?? entry.category;
          const canDelete = canManage || entry.authorProfileId === myProfileId;
          return (
            <AppCard key={entry._id}>
                <View style={{ gap: 6 }}>
                <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                    {entry.pinned ? <Text style={{ color: colors.primary }}>📌</Text> : null}
                    <Text style={{ fontWeight: '700' }}>{entry.authorName}</Text>
                    <Chip compact>{categoryLabel}</Chip>
                  </View>
                  {canDelete ? (
                    <IconButton icon="close" size={16} onPress={() => void onDelete(entry._id)} accessibilityLabel={t('logbook.removeEntryLabel')} />
                  ) : null}
                </View>
                <Text style={{ color: colors.charcoal, lineHeight: 20 }}>{entry.body}</Text>
                <Text style={{ color: colors.muted, fontSize: 12 }}>{formatTimestamp(entry.createdAt)}</Text>
                </View>
            </AppCard>
          );
        })
      )}
    </FormScreen>
  );
}

export default function LogbookScreenWrapper() {
  return <ScreenErrorBoundary withNavRail={false}><LogbookScreen /></ScreenErrorBoundary>;
}
