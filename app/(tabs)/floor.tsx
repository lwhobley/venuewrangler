import { useMemo, useState } from 'react';
import { Pressable, ScrollView, View } from 'react-native';
import { Button, Card, Chip, Text } from 'react-native-paper';
import { ScreenErrorBoundary } from '../../components/ErrorBoundary';
import { useMutation, useQuery, useQueryState } from '../../lib/railway-hooks';
import { api } from '../../lib/railway-api';
import type { Id } from '../../lib/ids';
import { colors, radius, spacing } from '../../lib/theme';
import { useVenueAuth } from '../../lib/useVenueAuth';
import { formatTime, errorMessage } from '../../lib/format';
import { SectionHeader } from '../../components/AppCard';
import { router } from 'expo-router';
import { useI18n } from '../../lib/i18n';

const sectionFilters = ['all', 'main', 'patio', 'bar', 'vip'] as const;
const statusColors: Record<string, string> = {
  available: '#2E6B4A',
  seated: '#2F4C8F',
  dirty: '#B58A22',
  reserved: '#7043A3',
  held: '#6B6B73',
  out_of_service: '#A23D3D',
};
const statusLabels: Record<string, string> = {
  available: 'Available',
  seated: 'Seated',
  dirty: 'Dirty',
  reserved: 'Reserved',
  held: 'Held',
  out_of_service: 'Out of service',
};

type AssignmentRow = {
  assignmentId: string;
  holdType: 'reserved' | 'held' | 'seated';
  sourceType: 'reservation' | 'waitlist';
  guestName: string;
  partySize: number;
  source: string;
  tags: string[];
  notes: string | null;
  status: string;
  startsAt: number;
  endsAt: number;
};

type SeatLabelStyle = 'number' | 'letter' | 'none';

type FloorTableRow = {
  table: {
    _id: string;
    label: string;
    shape: 'round' | 'square' | 'rect' | 'booth';
    seats: number;
    seatLabelStyle?: SeatLabelStyle | null;
    x: number;
    y: number;
    width: number;
    height: number;
    rotation: number;
    section: 'main' | 'patio' | 'bar' | 'vip';
    minSpend: number;
    isReservable: boolean;
  };
  state: {
    status: keyof typeof statusColors;
    partySize: number | null;
    notes: string | null;
    mergeGroupId?: string | null;
  } | null;
  activeAssignments: AssignmentRow[];
  nextAssignment: AssignmentRow | null;
};

type FloorChair = { _id: string; x: number; y: number; rotation: number; label: string | null };

type FloorData = {
  floorPlan: { name: string; width: number; height: number };
  tables: FloorTableRow[];
  chairs?: FloorChair[];
};

function seatText(style: SeatLabelStyle, i: number): string {
  if (style === 'none') return '';
  if (style === 'letter') return String.fromCharCode(65 + (i % 26));
  return String(i + 1);
}

function chairPositions(shape: string, w: number, h: number, seats: number): { x: number; y: number }[] {
  const out: { x: number; y: number }[] = [];
  if (seats <= 0) return out;
  if (shape === 'round') {
    const r = Math.max(w, h) / 2 + 9;
    for (let i = 0; i < seats; i++) {
      const a = (2 * Math.PI * i) / seats - Math.PI / 2;
      out.push({ x: w / 2 + r * Math.cos(a), y: h / 2 + r * Math.sin(a) });
    }
    return out;
  }
  const top = Math.ceil(seats / 2);
  const bottom = seats - top;
  for (let i = 0; i < top; i++) out.push({ x: ((i + 1) * w) / (top + 1), y: -9 });
  for (let i = 0; i < bottom; i++) out.push({ x: ((i + 1) * w) / (bottom + 1), y: h + 9 });
  return out;
}

type ReservationQueueItem = {
  id: string;
  guestName: string;
  partySize: number;
  reservationTime: number;
  durationMinutes: number;
  source: string;
  tags: string[];
  specialRequests: string | null;
  status: string;
  externalId: string | null;
};

type WaitlistItem = {
  id: string;
  guestName: string;
  partySize: number;
  requestedAt: number;
  source: string;
  status: string;
  // A party marked Ready stays in this queue (it is the only queue with a Seat
  // action); isReady is how the host tells the two apart.
  isReady?: boolean;
  readyAt?: number | null;
  notes: string | null;
};

type StatCard = { label: string; value: number | string };


export default function FloorScreenWrapper() {
  // The floor plan is a spatial canvas — a reading column makes it worse.
  return <ScreenErrorBoundary fullBleed><FloorScreen /></ScreenErrorBoundary>;
}

function FloorScreen() {
  const { venue, isReady, user, canManage: canEdit } = useVenueAuth();
  const { t } = useI18n();
  const [section, setSection] = useState<(typeof sectionFilters)[number]>('all');
  const [selectedTableId, setSelectedTableId] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<'all' | 'available' | 'dirty' | 'reserved' | 'seated'>('all');
  const [focusMode, setFocusMode] = useState(false);

  const floorQuery = useQueryState(api.floorBinding.getActiveFloorPlan, isReady && venue?.id ? { venueId: venue.id } : 'skip');
  const floor = floorQuery.data as FloorData | null | undefined;
  // Distinguishes "no floor plan built yet" from "the fetch failed" — these
  // used to render the same "Build one" empty state either way.
  const floorLoadFailed = isReady && Boolean(venue?.id) && !floorQuery.isLoading && floor === undefined && Boolean(floorQuery.error);
  const stats = useQuery(api.floor.getFloorStats, isReady && venue?.id ? { venueId: venue.id } : 'skip');
  const unassignedReservations = useQuery(api.floorBinding.getUnassignedReservations, isReady && venue?.id ? { venueId: venue.id, withinMinutes: 120 } : 'skip') as ReservationQueueItem[] | null | undefined;
  const openWaitlist = useQuery(api.floorBinding.getOpenWaitlist, isReady && venue?.id ? { venueId: venue.id } : 'skip') as WaitlistItem[] | null | undefined;

  const releaseAssignment = useMutation(api.floorBinding.releaseAssignment);
  const markDirty = useMutation(api.tables.markDirty);
  const markClean = useMutation(api.tables.markClean);
  const mergeTablesForParty = useMutation(api.tables.mergeTablesForParty);
  const splitMergedTables = useMutation(api.tables.splitMergedTables);

  const [mergeOpen, setMergeOpen] = useState(false);
  const [mergeSel, setMergeSel] = useState<string[]>([]);
  const [mergeParty, setMergeParty] = useState(6);
  const [actionError, setActionError] = useState<string | null>(null);


  const activeFloor = floor ?? null;
  const reservationQueue = unassignedReservations ?? [];
  const waitlistQueue = openWaitlist ?? [];

  const mergeableTables = useMemo(
    () => (activeFloor?.tables ?? []).filter((t: FloorTableRow) => !t.state?.mergeGroupId && (!t.state || t.state.status === 'available' || t.state.status === 'dirty' || t.state.status === 'seated')),
    [activeFloor],
  );
  const mergeGroups = useMemo(() => {
    const groups = new Map<string, FloorTableRow[]>();
    for (const t of activeFloor?.tables ?? []) {
      const g = t.state?.mergeGroupId;
      if (!g) continue;
      const list = groups.get(g) ?? [];
      list.push(t);
      groups.set(g, list);
    }
    return Array.from(groups.entries());
  }, [activeFloor]);

  const toggleMerge = (id: string) => setMergeSel((cur) => (cur.includes(id) ? cur.filter((x) => x !== id) : [...cur, id]));
  const doMerge = async () => {
    if (!venue?.id || mergeSel.length < 2) return;
    setActionError(null);
    try {
      await mergeTablesForParty({ venueId: venue.id, tableIds: mergeSel as Id<'tables'>[], partySize: mergeParty });
      setMergeSel([]);
      setMergeOpen(false);
    } catch (e) {
      setActionError(errorMessage(e, t('floor.mergeError')));
    }
  };

  const filteredTables = useMemo(() => {
    if (!activeFloor) return [];
    return activeFloor.tables.filter((item: FloorTableRow) => {
      const sectionMatches = section === 'all' || item.table.section === section;
      const state = item.state?.status ?? 'available';
      const statusMatches = statusFilter === 'all' || state === statusFilter;
      const focusMatches = !focusMode || state === 'dirty' || item.activeAssignments.length > 0 || Boolean(item.nextAssignment);
      return sectionMatches && statusMatches && focusMatches;
    });
  }, [activeFloor, focusMode, section, statusFilter]);

  const selected = filteredTables.find((item: FloorTableRow) => item.table._id === selectedTableId) ?? filteredTables[0] ?? null;
  const selectedState = selected?.state ?? null;
  const selectedAssignments = selected?.activeAssignments ?? [];
  const selectedNextAssignment = selected?.nextAssignment ?? null;
  const needsAssignmentCount = reservationQueue.length;
  const sectionLoad = useMemo(() => sectionFilters.slice(1).map((key) => {
    const tables = (activeFloor?.tables ?? []).filter((item: FloorTableRow) => item.table.section === key);
    const occupied = tables.filter((item: FloorTableRow) => ['seated', 'reserved'].includes(item.state?.status ?? '')).length;
    return { key, occupied, total: tables.length };
  }), [activeFloor]);
  const floorExceptions = useMemo(() => {
    const now = Date.now();
    const dirty = (activeFloor?.tables ?? []).filter((item: FloorTableRow) => item.state?.status === 'dirty').map((item: FloorTableRow) => `${item.table.label} needs cleaning`);
    const overdue = (activeFloor?.tables ?? []).flatMap((item: FloorTableRow) => item.activeAssignments.filter((assignment) => assignment.endsAt < now).map((assignment) => `${assignment.guestName} is past the expected turn at ${item.table.label}`));
    return [...reservationQueue.slice(0, 2).map((item) => `${item.guestName} needs a table`), ...dirty, ...overdue].slice(0, 5);
  }, [activeFloor, reservationQueue]);
  const nextParty = reservationQueue[0] ?? waitlistQueue[0] ?? null;
  const recommendedForNext = useMemo(() => {
    if (!nextParty) return [];
    return mergeableTables
      .filter((item) => (item.state?.status ?? 'available') === 'available' && item.activeAssignments.length === 0 && !item.nextAssignment && item.table.seats >= nextParty.partySize)
      .sort((a, b) => (a.table.seats - nextParty.partySize) - (b.table.seats - nextParty.partySize))
      .slice(0, 3);
  }, [mergeableTables, nextParty]);

  const onRelease = async (assignmentId: string) => {
    if (!venue?.id) return;
    setActionError(null);
    try {
      await releaseAssignment({
        venueId: venue.id,
        assignmentId: assignmentId as Id<'tableAssignments'>,
        reason: 'Released from floor screen',
        actorRole: user?.role ?? 'staff',
      });
    } catch (e) {
      setActionError(errorMessage(e, t('floor.releaseError')));
    }
  };

  const onMarkDirty = async (tableId: Id<'tables'>) => {
    setActionError(null);
    try {
      await markDirty({ tableId });
    } catch (e) {
      setActionError(errorMessage(e, t('floor.markDirtyError')));
    }
  };

  const onMarkClean = async (tableId: Id<'tables'>) => {
    setActionError(null);
    try {
      await markClean({ tableId });
    } catch (e) {
      setActionError(errorMessage(e, t('floor.markCleanError')));
    }
  };

  const onSplitMerge = async (mergeGroupId: string) => {
    if (!venue?.id) return;
    setActionError(null);
    try {
      await splitMergedTables({ venueId: venue.id, mergeGroupId });
    } catch (e) {
      setActionError(errorMessage(e, t('floor.splitError')));
    }
  };

  return (
    <ScrollView contentContainerStyle={{ flexGrow: 1, backgroundColor: colors.background, padding: spacing.lg, gap: spacing.md }}>
      <SectionHeader kicker={t('floor.kicker')} title={t('floor.title')} subtitle={t('floor.subtitle', { venue: venue?.name ?? t('common.yourVenue') })} />
      {actionError ? <Text style={{ color: colors.danger }}>{actionError}</Text> : null}

      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm }}>
        {([
          { label: t('floor.statOccupied'), value: stats?.occupiedCount ?? 0 },
          { label: t('floor.statAvgTurn'), value: `${stats?.avgTurnTimeMinutes ?? 0}m` },
          { label: t('floor.statLongestSeated'), value: `${stats?.longestSeatedDurationMinutes ?? 0}m` },
          { label: t('floor.statWaitlist'), value: stats?.waitlistSize ?? 0 },
        ] as StatCard[]).map((item) => (
          <Card key={item.label} style={{ backgroundColor: colors.surface, flexGrow: 1, minWidth: '46%' }}>
            <Card.Content style={{ gap: 4 }}>
              <Text style={{ color: colors.muted }}>{item.label}</Text>
              <Text variant="headlineSmall">{String(item.value)}</Text>
            </Card.Content>
          </Card>
        ))}
      </View>

      <Card style={{ backgroundColor: colors.surface }}>
        <Card.Content style={{ gap: spacing.sm }}>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'space-between', alignItems: 'center', gap: 12 }}>
            <View style={{ flexGrow: 1, flexShrink: 1, minWidth: 180 }}>
              <Text variant="titleMedium">{t('floor.needsAssignmentTitle')}</Text>
              <Text style={{ color: colors.muted }}>{t('floor.needsAssignmentDesc', { count: needsAssignmentCount })}</Text>
            </View>
            <Button
              mode="contained"
              buttonColor={colors.primary}
              style={{ alignSelf: 'flex-start', maxWidth: '100%' }}
              onPress={() => router.push('/reservations')}
            >
              {t('floor.openReservations')}
            </Button>
          </View>
          <Text style={{ color: colors.muted }}>
            {t('floor.needsAssignmentHelp')}
          </Text>
        </Card.Content>
      </Card>

      <Card style={{ backgroundColor: colors.surface }}>
        <Card.Content style={{ gap: spacing.sm }}>
          <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', gap: spacing.sm }}>
            <View style={{ flex: 1 }}>
              <Text variant="titleMedium">Next 30 minutes</Text>
              <Text style={{ color: colors.muted }}>Arrivals and waitlist parties that can be seated now.</Text>
            </View>
            <Button compact mode="text" textColor={colors.primary} onPress={() => router.push('/reservations')}>Open reservations</Button>
          </View>
          {nextParty ? (
            <>
              <View style={{ paddingVertical: spacing.sm, borderBottomWidth: 1, borderBottomColor: colors.border }}>
                <Text style={{ fontWeight: '700' }}>{nextParty.guestName} · {nextParty.partySize}</Text>
                <Text style={{ color: colors.muted, fontSize: 12 }}>{'reservationTime' in nextParty ? `Reservation at ${formatTime(nextParty.reservationTime)}` : (nextParty as WaitlistItem).isReady ? 'Ready to seat' : 'Waiting for a table'}</Text>
              </View>
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
                {recommendedForNext.length ? recommendedForNext.map((item) => (
                  <Chip key={item.table._id} onPress={() => { setSelectedTableId(item.table._id); setStatusFilter('all'); }}>
                    {item.table.label} · {item.table.seats} seats
                  </Chip>
                )) : <Text style={{ color: colors.warning }}>No single open table fits this party. Consider a merge.</Text>}
              </View>
            </>
          ) : <Text style={{ color: colors.muted }}>No upcoming unassigned arrivals or waitlist parties.</Text>}
        </Card.Content>
      </Card>

      {floorExceptions.length ? (
        <Card style={{ backgroundColor: '#FFF4DE', borderLeftWidth: 3, borderLeftColor: colors.warning }}>
          <Card.Content style={{ gap: spacing.xs }}>
            <Text variant="titleMedium">Floor exceptions</Text>
            {floorExceptions.map((item) => <Text key={item} style={{ color: colors.charcoal }}>• {item}</Text>)}
          </Card.Content>
        </Card>
      ) : null}

      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
        {sectionFilters.map((filter) => (
          <Chip key={filter} selected={section === filter} onPress={() => setSection(filter)}>
            {filter === 'all' ? t('floor.allSections') : filter}
          </Chip>
        ))}
      </View>

      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8, alignItems: 'center' }}>
        {(['all', 'available', 'dirty', 'reserved', 'seated'] as const).map((filter) => (
          <Chip key={filter} selected={statusFilter === filter} onPress={() => setStatusFilter(filter)}>{filter === 'all' ? 'All states' : statusLabels[filter]}</Chip>
        ))}
        <Chip selected={focusMode} onPress={() => setFocusMode((value) => !value)}>Focus active</Chip>
      </View>

      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8, paddingVertical: spacing.xs }}>
        {sectionLoad.map((item) => (
          <Text key={item.key} style={{ color: colors.muted, fontSize: 12 }}>{item.key.toUpperCase()} {item.occupied}/{item.total}</Text>
        ))}
      </View>

      {floorLoadFailed ? (
        <Card style={{ backgroundColor: colors.surface }}>
          <Card.Content style={{ gap: spacing.sm }}>
            <Text variant="titleMedium">Couldn't load the floor plan</Text>
            <Text style={{ color: colors.muted }}>Check your connection and try again.</Text>
            <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
              <Button mode="outlined" onPress={() => floorQuery.refetch()}>
                Retry
              </Button>
            </View>
          </Card.Content>
        </Card>
      ) : !activeFloor ? (
        <Card style={{ backgroundColor: colors.surface }}>
          <Card.Content style={{ gap: spacing.sm }}>
            <Text variant="titleMedium">{t('floor.noFloorPlanTitle')}</Text>
            <Text style={{ color: colors.muted }}>{t('floor.noFloorPlanDesc')}</Text>
            {canEdit ? (
              <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                <Button mode="contained" buttonColor={colors.primary} icon="pencil" onPress={() => router.push('/floor/editor')}>
                  {t('floor.buildFloorPlan')}
                </Button>
              </View>
            ) : null}
          </Card.Content>
        </Card>
      ) : (
        <Card style={{ backgroundColor: colors.surface }}>
          <Card.Content style={{ gap: spacing.sm }}>
            <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
              <Text variant="titleMedium">{activeFloor.floorPlan.name}</Text>
              {canEdit ? (
                <Button compact mode="outlined" textColor={colors.primary} icon="pencil" onPress={() => router.push('/floor/editor')}>
                  {t('floor.edit')}
                </Button>
              ) : null}
            </View>
            <ScrollView horizontal nestedScrollEnabled showsHorizontalScrollIndicator contentContainerStyle={{ minWidth: activeFloor.floorPlan.width }}
              style={{
                height: 560,
                borderRadius: radius.soft,
                backgroundColor: '#18120E',
                borderWidth: 1,
                borderColor: '#2C241D',
                overflow: 'hidden',
              }}
            >
              <ScrollView nestedScrollEnabled showsVerticalScrollIndicator contentContainerStyle={{ minHeight: activeFloor.floorPlan.height }}>
              <View style={{ width: activeFloor.floorPlan.width, height: activeFloor.floorPlan.height, minHeight: 560, position: 'relative' }}>
              {filteredTables.map(({ table, state, activeAssignments, nextAssignment }: FloorTableRow) => {
                const status = state?.status ?? 'available';
                const isSelected = selected?.table._id === table._id;
                const currentAssignment = activeAssignments?.[0] ?? null;
                return (
                  <Pressable
                    accessibilityRole="button"
                    key={table._id}
                    onPress={() => setSelectedTableId(table._id)}
                    style={{
                      position: 'absolute',
                      left: table.x,
                      top: table.y,
                      width: table.width,
                      height: table.height,
                      transform: [{ rotate: `${table.rotation}deg` }],
                      borderRadius: table.shape === 'round' ? 999 : table.shape === 'booth' ? 18 : 14,
                      borderWidth: isSelected ? 3 : 2,
                      borderColor: isSelected ? colors.cream : statusColors[status] ?? colors.primary,
                      backgroundColor: `${statusColors[status] ?? colors.primary}20`,
                      alignItems: 'center',
                      justifyContent: 'center',
                      padding: 8,
                    }}
                  >
                    {chairPositions(table.shape, table.width, table.height, table.seats).map((c, i) => {
                      const lbl = seatText((table.seatLabelStyle ?? 'number') as SeatLabelStyle, i);
                      const sz = lbl ? 16 : 10;
                      return (
                        <View
                          key={i}
                          pointerEvents="none"
                          style={{
                            position: 'absolute',
                            left: c.x - sz / 2,
                            top: c.y - sz / 2,
                            width: sz,
                            height: sz,
                            borderRadius: sz / 2,
                            backgroundColor: '#cbd2e0',
                            alignItems: 'center',
                            justifyContent: 'center',
                          }}
                        >
                          {lbl ? <Text style={{ fontSize: 9, fontWeight: '700', color: '#2a2f42' }}>{lbl}</Text> : null}
                        </View>
                      );
                    })}
                    <Text style={{ color: colors.cream, fontWeight: '700' }}>{table.label}</Text>
                    <Text style={{ color: colors.cream, fontSize: 12 }}>{t('floor.seatsLabel', { count: table.seats })}</Text>
                    {currentAssignment ? (
                      <View style={{ marginTop: 4, alignItems: 'center' }}>
                        <Text style={{ color: colors.cream, fontSize: 11, fontWeight: '700' }}>{currentAssignment.guestName}</Text>
                        <Text style={{ color: colors.cream, fontSize: 10 }}>{currentAssignment.partySize}p · {formatTime(currentAssignment.startsAt)}</Text>
                      </View>
                    ) : nextAssignment ? (
                      <Text style={{ color: colors.cream, fontSize: 10, marginTop: 4 }}>{t('floor.nextGuest', { name: nextAssignment.guestName })}</Text>
                    ) : null}
                  </Pressable>
                );
              })}
              {(activeFloor.chairs ?? []).map((chair: FloorChair) => (
                <View
                  key={chair._id}
                  pointerEvents="none"
                  style={{
                    position: 'absolute',
                    left: chair.x,
                    top: chair.y,
                    width: 30,
                    height: 30,
                    alignItems: 'center',
                    justifyContent: 'center',
                    transform: [{ rotate: `${chair.rotation}deg` }],
                  }}
                >
                  <View style={{ width: '78%', height: '78%', borderRadius: 6, backgroundColor: '#9aa3b8' }} />
                  <View style={{ position: 'absolute', top: 0, width: '78%', height: '26%', borderTopLeftRadius: 6, borderTopRightRadius: 6, backgroundColor: '#6b7488' }} />
                  {chair.label ? (
                    <View style={{ position: 'absolute', bottom: -13, width: 70, alignItems: 'center', left: 15 - 35 }}>
                      <Text style={{ fontSize: 9, fontWeight: '700', color: '#cbd2e0' }} numberOfLines={1}>{chair.label}</Text>
                    </View>
                  ) : null}
                </View>
              ))}
              </View>
              </ScrollView>
            </ScrollView>
          </Card.Content>
        </Card>
      )}

      {canEdit && activeFloor ? (
        <Card style={{ backgroundColor: colors.surface }}>
          <Card.Content style={{ gap: spacing.sm }}>
            <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', gap: spacing.sm }}>
              <View style={{ flex: 1 }}>
                <Text variant="titleMedium" style={{ fontWeight: '700' }}>{t('floor.mergeTablesTitle')}</Text>
                <Text style={{ color: colors.muted }}>{t('floor.mergeTablesDesc')}</Text>
              </View>
              <Button mode={mergeOpen ? 'contained-tonal' : 'outlined'} onPress={() => setMergeOpen((value) => !value)}>
                {mergeOpen ? t('floor.close') : t('floor.merge')}
              </Button>
            </View>

            {mergeGroups.length > 0 ? (
              <View style={{ gap: 8 }}>
                {mergeGroups.map(([groupId, tables]) => (
                  <View key={groupId} style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: spacing.sm, paddingVertical: 6 }}>
                    <Text style={{ flex: 1, color: colors.muted }}>
                      {tables.map((table) => table.table.label).join(' + ')}
                    </Text>
                    <Button compact mode="outlined" onPress={() => void onSplitMerge(groupId)}>
                      {t('floor.split')}
                    </Button>
                  </View>
                ))}
              </View>
            ) : null}

            {mergeOpen ? (
              <View style={{ gap: spacing.sm }}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.sm }}>
                  <Text style={{ color: colors.muted, flex: 1 }}>{t('floor.partySize')}</Text>
                  <Button compact mode="outlined" onPress={() => setMergeParty((value) => Math.max(2, value - 1))}>-</Button>
                  <Chip compact>{mergeParty}</Chip>
                  <Button compact mode="outlined" onPress={() => setMergeParty((value) => Math.min(50, value + 1))}>+</Button>
                </View>
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                  {mergeableTables.map((item) => {
                    const selectedForMerge = mergeSel.includes(item.table._id);
                    return (
                      <Chip
                        key={item.table._id}
                        selected={selectedForMerge}
                        onPress={() => toggleMerge(item.table._id)}
                        style={{ backgroundColor: selectedForMerge ? colors.primary : colors.background }}
                        textStyle={{ color: selectedForMerge ? '#fff' : colors.charcoal }}
                      >
                        {item.table.label}
                      </Chip>
                    );
                  })}
                </View>
                {mergeableTables.length === 0 ? <Text style={{ color: colors.muted }}>{t('floor.noAvailableTables')}</Text> : null}
                <Button mode="contained" buttonColor={colors.primary} disabled={mergeSel.length < 2} onPress={() => void doMerge()}>
                  {t('floor.mergeSelected')}
                </Button>
              </View>
            ) : null}
          </Card.Content>
        </Card>
      ) : null}

      {selected ? (
        <Card style={{ backgroundColor: colors.surface }}>
          <Card.Content style={{ gap: spacing.sm }}>
            <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
              <View>
                <Text variant="titleMedium">{selected.table.label}</Text>
                <Text style={{ color: colors.muted }}>{selected.table.section === 'vip' ? 'VIP' : selected.table.section.charAt(0).toUpperCase() + selected.table.section.slice(1)} · {t('floor.seatsLabel', { count: selected.table.seats })}</Text>
              </View>
              <Chip selected style={{ backgroundColor: `${statusColors[selectedState?.status ?? 'available']}22` }}>
                {statusLabels[selectedState?.status ?? 'available']}
              </Chip>
            </View>
            <Text style={{ color: colors.muted }}>
              {t('floor.partySizeNotes', { size: selectedState?.partySize ?? 0, notes: selectedState?.notes ?? t('floor.noNotes') })}
            </Text>

            {selectedAssignments.length > 0 ? (
              <View style={{ gap: 8 }}>
                {selectedAssignments.map((assignment: AssignmentRow) => (
                  <Card key={assignment.assignmentId} style={{ backgroundColor: '#201812' }}>
                    <Card.Content style={{ gap: 6 }}>
                      <Text style={{ color: colors.cream, fontWeight: '700' }}>{assignment.guestName}</Text>
                      <Text style={{ color: colors.cream, fontSize: 12 }}>
                        {assignment.source} · {formatTime(assignment.startsAt)} - {formatTime(assignment.endsAt)}
                      </Text>
                      <Text style={{ color: colors.cream, fontSize: 12 }}>{t('floor.partyOf', { size: assignment.partySize })}</Text>
                      {assignment.notes ? <Text style={{ color: colors.cream, fontSize: 12 }}>{assignment.notes}</Text> : null}
                      {assignment.tags.length > 0 ? (
                        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
                          {assignment.tags.map((tag) => (
                            <Chip key={tag} compact style={{ backgroundColor: colors.cream }} textStyle={{ color: colors.charcoal }}>
                              {tag}
                            </Chip>
                          ))}
                        </View>
                      ) : null}
                      {canEdit ? (
                        <Button mode="text" textColor={colors.primary} onPress={() => void onRelease(assignment.assignmentId)}>
                          {t('floor.release')}
                        </Button>
                      ) : null}
                    </Card.Content>
                  </Card>
                ))}
              </View>
            ) : selectedNextAssignment ? (
              <Text style={{ color: colors.muted }}>{t('floor.nextUp', { name: selectedNextAssignment.guestName, time: formatTime(selectedNextAssignment.startsAt) })}</Text>
            ) : null}

            {canEdit ? (
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                <Button mode="outlined" onPress={() => void onMarkDirty(selected.table._id as Id<'tables'>)}>
                  {t('floor.markDirty')}
                </Button>
                <Button mode="outlined" onPress={() => void onMarkClean(selected.table._id as Id<'tables'>)}>
                  {t('floor.markClean')}
                </Button>
              </View>
            ) : (
              <Text style={{ color: colors.muted }}>
                {t('floor.staffViewOnly')}
              </Text>
            )}
          </Card.Content>
        </Card>
      ) : null}

    </ScrollView>
  );
}
