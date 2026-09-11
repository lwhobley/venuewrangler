import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { FlatList, View } from 'react-native';
import { Button, Card, Chip, IconButton, Menu, Text, TextInput } from 'react-native-paper';
import { ScreenErrorBoundary } from '../components/ErrorBoundary';
import { router } from 'expo-router';
import { useI18n } from '../lib/i18n';
import { useMutation, useQuery, useQueryState } from '../lib/railway-hooks';
import { api } from '../lib/railway-api';
import type { Id } from '../lib/ids';
import { accents, colors, spacing, radius, type } from '../lib/theme';
import { AppCard, SectionHeader } from '../components/AppCard';
import { useAuthStore, type AuthState } from '../lib/auth-store';
import { useAuthenticatedSession } from '../lib/auth-readiness';
import { canManageVenue } from '../lib/permissions';
import { formatTime, formatShortDate, formatWeekdayDate, pad2, dollarsToCents, splitTags, errorMessage } from '../lib/format';
import { DateRangeBar, useDateRange } from '../components/DateRangeBar';
import { overnightAwareRange, zonedDayIndex, zonedDateTimeMs } from '../lib/zoned-datetime';

const reservationSources = ['direct', 'opentable', 'resy', 'phone', 'walk_in'] as const;
type Source = (typeof reservationSources)[number];

type MealId = 'breakfast' | 'brunch' | 'lunch' | 'dinner';

const MEAL_TIMES: Record<MealId, { id: MealId; time: string; duration: number }> = {
  breakfast: { id: 'breakfast', time: '08:00', duration: 60 },
  brunch: { id: 'brunch', time: '10:00', duration: 90 },
  lunch: { id: 'lunch', time: '12:00', duration: 90 },
  dinner: { id: 'dinner', time: '18:00', duration: 120 },
};

function getMealsForDayOfWeek(dow: number) {
  const isWeekend = dow === 0 || dow === 6;
  return isWeekend
    ? [MEAL_TIMES.brunch, MEAL_TIMES.dinner]
    : [MEAL_TIMES.breakfast, MEAL_TIMES.lunch, MEAL_TIMES.dinner];
}

/** Today's YYYY-MM-DD in the venue's timezone (device-local fallback). */
function zonedTodayIso(timeZone: string | null | undefined): string {
  try {
    return new Intl.DateTimeFormat('en-CA', {
      timeZone: timeZone || undefined,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    }).format(new Date());
  } catch {
    const n = new Date();
    return `${n.getFullYear()}-${pad2(n.getMonth() + 1)}-${pad2(n.getDate())}`;
  }
}

type ReservationRow = {
  id: string;
  _id?: string;
  guestName: string;
  guestCompany?: string | null;
  partySize: number;
  reservationTime: number;
  durationMinutes: number;
  source: string;
  status: string;
  tags: string[];
  occasion?: string | null;
  specialRequests: string | null;
  notes: string | null;
  isPrivateEvent?: boolean;
  eventName?: string | null;
  eventStatus?: string | null;
  eventSpace?: string | null;
  setupStyle?: string | null;
  menuNotes?: string | null;
  beverageNotes?: string | null;
  billingNotes?: string | null;
  estimatedValueCents?: number | null;
  depositDueCents?: number | null;
};

type FloorTable = {
  table: { _id: string; label: string; section: string; seats: number; isReservable?: boolean };
  state: { status: string } | null;
};

const statusColor: Record<string, { bg: string; fg: string }> = {
  requested: { bg: accents[4].bg, fg: accents[4].fg },
  confirmed: { bg: accents[0].bg, fg: accents[0].fg },
  checked_in: { bg: accents[3].bg, fg: accents[3].fg },
  seated: { bg: accents[2].bg, fg: accents[2].fg },
  completed: { bg: colors.cream, fg: colors.muted },
  no_show: { bg: '#FDE7E9', fg: colors.danger },
  cancelled: { bg: '#FDE7E9', fg: colors.danger },
};



export default function ReservationsScreenWrapper() {
  return <ScreenErrorBoundary withNavRail={false}><ReservationsScreen /></ScreenErrorBoundary>;
}

function ReservationsScreen() {
  const { t } = useI18n();
  const venue = useAuthStore((state: AuthState) => state.venue);
  const { isReady } = useAuthenticatedSession();
  const me = useQuery(api.app.getMe, isReady ? {} : 'skip');
  const canManage = Boolean(me && canManageVenue(me.profile.role, me.profile.allAccess));

  const { data: page, error: pageError, isLoading: pageLoading, refetch: refetchPage } = useQueryState(api.reservations.getReservationsPage, isReady && venue?.id ? { venueId: venue.id } : 'skip') as any;
  const floor = useQuery(api.floorBinding.getActiveFloorPlan, isReady && venue?.id ? { venueId: venue.id } : 'skip') as any;
  const waitlistData = useQuery(api.floorBinding.getOpenWaitlist, isReady && venue?.id ? { venueId: venue.id } : 'skip') as any;
  const unassignedData = useQuery(api.floorBinding.getUnassignedReservations, isReady && venue?.id ? { venueId: venue.id, withinMinutes: 120 } : 'skip') as any;
  const holds = useQuery(api.reservations.listHolds, isReady && venue?.id ? { venueId: venue.id } : 'skip') as Array<{ id: string; startsAt: number; endsAt: number; reason: string }> | undefined;
  const saveReservation = useMutation(api.reservations.saveReservation);
  const removeReservation = useMutation(api.reservations.removeReservation);
  const assignReservation = useMutation(api.floorBinding.assignReservationToTables);
  const addToWaitlist = useMutation(api.floorBinding.addToWaitlist);
  const markWaitlistReady = useMutation(api.floorBinding.markWaitlistReady);
  const removeFromWaitlist = useMutation(api.floorBinding.removeFromWaitlist);
  const assignWaitlist = useMutation(api.floorBinding.assignWaitlistToTables);
  const createHold = useMutation(api.reservations.createHold);
  const deleteHold = useMutation(api.reservations.deleteHold);

  // Waitlist form/state
  const [wlName, setWlName] = useState('');
  const [wlParty, setWlParty] = useState(2);
  const [wlPhone, setWlPhone] = useState('');
  const [wlEmail, setWlEmail] = useState('');
  const [seatingWaitlistId, setSeatingWaitlistId] = useState<string | null>(null);
  const waitlist = useMemo(() => (waitlistData ?? []) as Array<{ id: string; guestName: string; partySize: number; requestedAt: number; readyAt: number | null; notes: string | null }>, [waitlistData]);

  const addWalkIn = async () => {
    if (walkInRef.current || !venue?.id || !wlName.trim()) return;
    walkInRef.current = true;
    setWaitlistError(null);
    try {
      await addToWaitlist({
        venueId: venue.id,
        guestName: wlName.trim(),
        partySize: wlParty,
        guestPhone: wlPhone.trim() || undefined,
        email: wlEmail.trim() || undefined,
      });
      setWlName('');
      setWlPhone('');
      setWlEmail('');
      setWlParty(2);
    } catch (e) {
      setWaitlistError(errorMessage(e, t('reservations.waitlist.errors.addFailed')));
    } finally {
      walkInRef.current = false;
    }
  };

  const seatWaitlist = async (entryId: string, tableId: string) => {
    if (!venue?.id) return;
    setWaitlistError(null);
    try {
      const startsAt = Date.now();
      await assignWaitlist({ venueId: venue.id, waitlistId: entryId as Id<'waitlist'>, tableIds: [tableId as Id<'tables'>], holdType: 'seated', startsAt, endsAt: startsAt + 120 * 60 * 1000 });
      setSeatingWaitlistId(null);
    } catch (e) {
      setWaitlistError(errorMessage(e, t('reservations.waitlist.errors.seatFailed')));
    }
  };

  const handleMarkWaitlistReady = async (waitlistId: string) => {
    if (!venue?.id) return;
    setWaitlistError(null);
    try {
      await markWaitlistReady({ venueId: venue.id, waitlistId: waitlistId as Id<'waitlist'> });
    } catch (e) {
      setWaitlistError(errorMessage(e, t('reservations.waitlist.errors.markReadyFailed')));
    }
  };

  const handleRemoveFromWaitlist = async (waitlistId: string) => {
    if (!venue?.id) return;
    setWaitlistError(null);
    try {
      await removeFromWaitlist({ venueId: venue.id, waitlistId: waitlistId as Id<'waitlist'> });
    } catch (e) {
      setWaitlistError(errorMessage(e, t('reservations.waitlist.errors.removeFailed')));
    }
  };

  const reservations = useMemo(
    () => ((page?.reservations ?? []) as ReservationRow[]).map((reservation) => ({ ...reservation, id: reservation.id ?? reservation._id ?? '' })),
    [page],
  );
  const tables = useMemo(() => (floor?.tables ?? []) as FloorTable[], [floor]);
  const openTables = useMemo(
    () => tables.filter((t) => t.table.isReservable !== false && (!t.state || t.state.status === 'available' || t.state.status === 'dirty')),
    [tables],
  );

  // New reservation form
  const now = new Date();
  const [showForm, setShowForm] = useState(false);
  const [showPrivateEventForm, setShowPrivateEventForm] = useState(false);
  const [guestFirstName, setGuestFirstName] = useState('');
  const [guestLastName, setGuestLastName] = useState('');
  const [guestPhone, setGuestPhone] = useState('');
  const [guestEmail, setGuestEmail] = useState('');
  const [guestCompany, setGuestCompany] = useState('');
  const [partySize, setPartySize] = useState(2);
  const [date, setDate] = useState(`${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`);
  const [time, setTime] = useState('18:00');
  const [selectedMeal, setSelectedMeal] = useState<MealId>('dinner');
  const [dateMenuOpen, setDateMenuOpen] = useState(false);
  const [mealMenuOpen, setMealMenuOpen] = useState(false);
  const [source, setSource] = useState<Source>('direct');
  const [tags, setTags] = useState('');
  const [occasion, setOccasion] = useState('');
  const [notes, setNotes] = useState('');
  const [eventName, setEventName] = useState('');
  const [eventSpace, setEventSpace] = useState('');
  const [setupStyle, setSetupStyle] = useState('');
  const [menuNotes, setMenuNotes] = useState('');
  const [beverageNotes, setBeverageNotes] = useState('');
  const [billingNotes, setBillingNotes] = useState('');
  const [estimatedValue, setEstimatedValue] = useState('');
  const [depositDue, setDepositDue] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  // Synchronous guards. These create money-bearing records (reservations carry
  // estimatedValueCents/depositDueCents for private events), so a double-tap
  // duplicating one is a real booking problem, not just a UI blemish.
  const creatingRef = useRef(false);
  const walkInRef = useRef(false);
  const holdRef = useRef(false);
  const deletingResRef = useRef(false);
  const [waitlistError, setWaitlistError] = useState<string | null>(null);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const [assignError, setAssignError] = useState<string | null>(null);

  const [assigningId, setAssigningId] = useState<string | null>(null);
  const [reservationFilter, setReservationFilter] = useState<'all' | 'now' | 'unseated' | 'vip' | 'large'>('all');
  const [guestContextId, setGuestContextId] = useState<string | null>(null);

  // Pacing chart bound to the create-form date so the manager sees the load
  // they're about to add to.
  const pacing = useQuery(
    api.reservations.getCoverPacing,
    isReady && venue?.id && date ? { venueId: venue.id, date } : 'skip',
  ) as { date: string; seatingCapacity: number; peakCovers: number; totalReservations: number; buckets: Array<{ startsAt: number; covers: number }> } | undefined;

  // Guest autofill: looks up an existing Guest by email or phone. Surfaces
  // preferences inline so hosts don't have to re-ask "do you still want
  // table 12?" every visit.
  const autofillKey = guestEmail.trim() || guestPhone.replace(/[^\d+]/g, '');
  const autofill = useQuery(
    api.reservations.guestAutofill,
    isReady && venue?.id && showForm && autofillKey.length >= 3
      ? { venueId: venue.id, email: guestEmail.trim() || undefined, phone: guestPhone.replace(/[^\d+]/g, '') || undefined }
      : 'skip',
  ) as { guest: { id: string; fullName: string; favoriteTable: string | null; preferredServer: string | null; dietaryNotes: string | null; tags: string[]; lifecycleStage: string | null; lastVisitAt: number | null; lastPartySize: number | null } | null } | undefined;

  // Hold form
  const [holdDate, setHoldDate] = useState('');
  const [holdStart, setHoldStart] = useState('19:00');
  const [holdEnd, setHoldEnd] = useState('22:00');
  const [holdReason, setHoldReason] = useState('');
  const [holdError, setHoldError] = useState<string | null>(null);

  const submitHold = async () => {
    if (holdRef.current || !venue?.id || !holdDate || !holdReason.trim()) {
      if (!holdRef.current) setHoldError(t('reservations.holds.errors.required'));
      return;
    }
    holdRef.current = true;
    try {
      const tz = me?.venue?.timezone ?? venue?.timezone;
      const { start, end } = overnightAwareRange(holdDate, holdStart, holdEnd, tz);
      const startsAt = new Date(start).toISOString();
      const endsAt = new Date(end).toISOString();
      await createHold({ venueId: venue.id, startsAt, endsAt, reason: holdReason.trim() });
      setHoldReason('');
      setHoldError(null);
    } catch (err) {
      setHoldError(errorMessage(err, t('reservations.holds.errors.createFailed')));
    } finally {
      holdRef.current = false;
    }
  };

  const { selected: listDateRange, setSelected: setListDateRange, presets: listPresets } = useDateRange('today', venue?.timezone);

  const sorted = useMemo(() => {
    const { startTs, endTs } = listDateRange;
    return [...reservations]
      .filter((r) => r.reservationTime >= startTs && r.reservationTime <= endTs)
      .sort((a, b) => a.reservationTime - b.reservationTime);
  }, [reservations, listDateRange]);

  const unassignedIds = useMemo(() => new Set((unassignedData ?? []).map((item: { id: string }) => item.id)), [unassignedData]);
  const actionReservations = useMemo(() => {
    const cutoff = Date.now() + 90 * 60 * 1000;
    return reservations
      .filter((item) => unassignedIds.has(item.id) || (item.reservationTime <= cutoff && !['seated', 'completed', 'cancelled', 'no_show'].includes(item.status)))
      .sort((a, b) => a.reservationTime - b.reservationTime)
      .slice(0, 4);
  }, [reservations, unassignedIds]);
  const visibleReservations = useMemo(() => {
    const nowTs = Date.now();
    return sorted.filter((item) => {
      if (reservationFilter === 'now') return item.reservationTime >= nowTs - 30 * 60 * 1000 && item.reservationTime <= nowTs + 90 * 60 * 1000;
      if (reservationFilter === 'unseated') return unassignedIds.has(item.id);
      if (reservationFilter === 'vip') return item.tags.some((tag) => /vip|regular|priority/i.test(tag));
      if (reservationFilter === 'large') return item.partySize >= 8;
      return true;
    });
  }, [reservationFilter, sorted, unassignedIds]);
  const recommendedTables = useCallback((party: number) => (
    [...openTables].filter((item) => item.table.seats >= party).sort((a, b) => (a.table.seats - party) - (b.table.seats - party))
  ), [openTables]);

  // Anchor the date picker on the venue's business day — the device clock can
  // already be on the venue's "tomorrow" (or yesterday) near midnight.
  const venueTimezone = me?.venue?.timezone ?? venue?.timezone ?? null;
  const todayStr = zonedTodayIso(venueTimezone);
  const dateOptions = useMemo(() => {
    const [y, m, d] = todayStr.split('-').map(Number);
    return Array.from({ length: 14 }, (_, i) => {
      const utcMs = Date.UTC(y, m - 1, d + i);
      const value = new Date(utcMs).toISOString().slice(0, 10);
      const display = new Date(utcMs);
      const label = i === 0 ? t('reservations.form.dateToday', { date: display.toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' }) }) : i === 1 ? t('reservations.form.dateTomorrow', { date: display.toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' }) }) : display.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' });
      return { value, label, dayOfWeek: display.getUTCDay() };
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [todayStr]);

  const selectedDateOption = dateOptions.find((o) => o.value === date) ?? dateOptions[0];
  const availableMeals = getMealsForDayOfWeek(selectedDateOption?.dayOfWeek ?? zonedDayIndex(venueTimezone));

  // Until the user picks a date themselves, follow the venue's business day —
  // the mount-time default came from the device clock, which near midnight can
  // disagree with the venue (or the venue timezone loads after mount).
  const dateTouchedRef = useRef(false);
  useEffect(() => {
    if (!dateTouchedRef.current) setDate(todayStr);
  }, [todayStr]);

  const createReservation = async () => {
    if (creatingRef.current) return;
    setError(null);
    const firstName = guestFirstName.trim();
    const lastName = guestLastName.trim();
    const fullName = [firstName, lastName].filter(Boolean).join(' ');
    if (!venue?.id || !firstName || !lastName) {
      setError(t('reservations.form.errors.nameRequired'));
      return;
    }
    const ts = zonedDateTimeMs(date, time, me?.venue?.timezone ?? venue?.timezone);
    if (Number.isNaN(ts)) {
      setError(t('reservations.form.errors.invalidDateTime'));
      return;
    }
    creatingRef.current = true;
    setCreating(true);
    try {
      await saveReservation({
        venueId: venue.id,
        guestName: fullName,
        guestPhone: guestPhone.trim() || undefined,
        guestEmail: guestEmail.trim() || undefined,
        guestCompany: guestCompany.trim() || undefined,
        partySize,
        reservationTime: ts,
        durationMinutes: showPrivateEventForm ? 240 : (MEAL_TIMES[selectedMeal]?.duration ?? 120),
        source,
        status: 'confirmed',
        tags: splitTags(tags),
        occasion: occasion.trim() || undefined,
        specialRequests: notes.trim() || undefined,
        notes: notes.trim() || undefined,
        isPrivateEvent: showPrivateEventForm,
        eventName: showPrivateEventForm ? eventName.trim() || undefined : undefined,
        eventStatus: showPrivateEventForm ? 'proposal' : undefined,
        eventSpace: showPrivateEventForm ? eventSpace.trim() || undefined : undefined,
        setupStyle: showPrivateEventForm ? setupStyle.trim() || undefined : undefined,
        menuNotes: showPrivateEventForm ? menuNotes.trim() || undefined : undefined,
        beverageNotes: showPrivateEventForm ? beverageNotes.trim() || undefined : undefined,
        billingNotes: showPrivateEventForm ? billingNotes.trim() || undefined : undefined,
        contractStatus: showPrivateEventForm ? 'draft' : undefined,
        beoStatus: showPrivateEventForm ? 'draft' : undefined,
        estimatedValueCents: showPrivateEventForm ? dollarsToCents(estimatedValue) : undefined,
        depositDueCents: showPrivateEventForm ? dollarsToCents(depositDue) : undefined,
      });
      setGuestFirstName('');
      setGuestLastName('');
      setGuestPhone('');
      setGuestEmail('');
      setGuestCompany('');
      setTags('');
      setOccasion('');
      setNotes('');
      setEventName('');
      setEventSpace('');
      setSetupStyle('');
      setMenuNotes('');
      setBeverageNotes('');
      setBillingNotes('');
      setEstimatedValue('');
      setDepositDue('');
      setPartySize(2);
      const todayDow = dateOptions[0]?.dayOfWeek ?? zonedDayIndex(venueTimezone);
      setSelectedMeal(todayDow === 0 || todayDow === 6 ? 'brunch' : 'dinner');
      setTime(todayDow === 0 || todayDow === 6 ? '10:00' : '18:00');
      setShowForm(false);
      setShowPrivateEventForm(false);
    } catch (e) {
      setError(errorMessage(e, t('reservations.form.errors.createFailed')));
    } finally {
      creatingRef.current = false;
      setCreating(false);
    }
  };

  const assignToTable = async (res: ReservationRow, tableId: string, seat: boolean) => {
    if (!venue?.id) return;
    setAssignError(null);
    try {
      const startsAt = res.reservationTime;
      const endsAt = startsAt + (res.durationMinutes || 120) * 60 * 1000;
      await assignReservation({
        venueId: venue.id,
        reservationId: res.id as Id<'reservations'>,
        tableIds: [tableId as Id<'tables'>],
        holdType: seat ? 'seated' : 'reserved',
        startsAt,
        endsAt,
      });
      setAssigningId(null);
    } catch (e) {
      setAssignError(errorMessage(e, t('reservations.item.assignFailed')));
    }
  };

  const deleteReservation = async (res: ReservationRow) => {
    if (deletingResRef.current || !venue?.id) return;
    deletingResRef.current = true;
    setDeleteError(null);
    try {
      await removeReservation({ venueId: venue.id, reservationId: res.id as Id<'reservations'> });
    } catch (e) {
      setDeleteError(errorMessage(e, t('reservations.list.deleteFailed')));
    } finally {
      deletingResRef.current = false;
    }
  };

  const statCards = useMemo(
    () => [
      { label: t('reservations.stats.active'), value: page?.activeCount ?? 0, a: accents[2] },
      { label: t('reservations.stats.upcoming'), value: page?.upcomingCount ?? 0, a: accents[0] },
      { label: t('reservations.stats.privateEvents'), value: reservations.filter((item) => item.isPrivateEvent).length, a: accents[5] },
      { label: t('reservations.stats.cancelled'), value: page?.cancelledCount ?? 0, a: accents[1] },
    ],
    [page, reservations, t],
  );

  return (
    <FlatList
      data={visibleReservations}
      keyExtractor={(item) => item.id}
      style={{ flex: 1, backgroundColor: colors.background }}
      contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xxl }}
      showsVerticalScrollIndicator={false}
      removeClippedSubviews
      ListHeaderComponent={(
        <>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <View style={{ gap: 4, flex: 1 }}>
          <Text style={{ ...type.title, color: colors.charcoal }}>{t('reservations.header.title')}</Text>
          <Text style={{ color: colors.muted }}>{t('reservations.header.subtitle', { venue: venue?.name ?? t('reservations.header.venueFallback') })}</Text>
        </View>
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'flex-end', gap: 6 }}>
          <Button compact mode="text" textColor={colors.primary} icon="floor-plan" onPress={() => router.push('/floor')}>{t('reservations.header.floorButton')}</Button>
          {canManage ? (
            <Button compact mode="text" textColor={colors.primary} icon="account-heart-outline" onPress={() => router.push('/guests')}>{t('reservations.header.guestsButton')}</Button>
          ) : null}
        </View>
      </View>

      {/* Stats */}
      <View style={{ flexDirection: 'row', gap: spacing.sm }}>
        {statCards.map((s) => (
          <Card key={s.label} style={{ flex: 1, backgroundColor: s.a.bg, borderRadius: radius.sharp }}>
            <Card.Content style={{ gap: 2 }}>
              <Text style={{ color: s.a.fg, fontSize: 24, fontWeight: '800' }}>{s.value}</Text>
              <Text style={{ color: colors.charcoal }}>{s.label}</Text>
            </Card.Content>
          </Card>
        ))}
      </View>

      <AppCard>
        <SectionHeader title="Resolve next" subtitle="Reservations that need a decision before service gets busier." />
        {actionReservations.length === 0 ? (
          <Text style={{ color: colors.muted }}>No unassigned or imminent reservations right now.</Text>
        ) : actionReservations.map((item) => (
          <View key={item.id} style={{ flexDirection: 'row', gap: spacing.sm, alignItems: 'center', paddingVertical: spacing.sm, borderBottomWidth: 1, borderBottomColor: colors.border }}>
            <View style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: unassignedIds.has(item.id) ? colors.warning : colors.primary }} />
            <View style={{ flex: 1, gap: 1 }}>
              <Text style={{ fontWeight: '700' }}>{item.guestName} · {item.partySize}</Text>
              <Text style={{ color: colors.muted, fontSize: 12 }}>{formatTime(item.reservationTime)} · {unassignedIds.has(item.id) ? 'Needs a table' : 'Arriving soon'}</Text>
            </View>
            <Button compact mode="text" textColor={colors.primary} onPress={() => setAssigningId(item.id)}>Seat</Button>
          </View>
        ))}
      </AppCard>

      {/* Cover pacing */}
      {pacing && pacing.buckets.length > 0 ? (
        <AppCard>
            <SectionHeader title={t('reservations.pacing.title', { date: pacing.date })} subtitle={t('reservations.pacing.subtitle', { peak: pacing.peakCovers, total: pacing.totalReservations, capacity: pacing.seatingCapacity || '—' })} />
            <View style={{ flexDirection: 'row', alignItems: 'flex-end', gap: 2, height: 100 }}>
              {pacing.buckets.map((b, i) => {
                const ratio = pacing.peakCovers > 0 ? b.covers / pacing.peakCovers : 0;
                const overCapacity = pacing.seatingCapacity > 0 && b.covers > pacing.seatingCapacity;
                return (
                  <View key={i} style={{ flex: 1, height: '100%', justifyContent: 'flex-end' }}>
                    <View style={{ height: `${Math.max(2, ratio * 100)}%`, backgroundColor: overCapacity ? colors.danger : colors.primary, borderRadius: radius.sharp }} />
                  </View>
                );
              })}
            </View>
            {pacing.seatingCapacity > 0 && pacing.peakCovers > pacing.seatingCapacity ? (
              <Text style={{ color: colors.danger, fontSize: 12, fontWeight: '700', marginTop: spacing.sm }}>
                {t('reservations.pacing.warning')}
              </Text>
            ) : null}
        </AppCard>
      ) : null}

      {/* Reservation holds */}
      <AppCard>
          <SectionHeader title={t('reservations.holds.title')} subtitle={t('reservations.holds.subtitle')} />
          <View style={{ gap: spacing.sm }}>
          <View style={{ flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' }}>
            <TextInput label={t('reservations.holds.dateLabel')} value={holdDate} onChangeText={setHoldDate} mode="outlined" dense placeholder="YYYY-MM-DD" style={{ width: 150, backgroundColor: colors.surface }} />
            <TextInput label={t('reservations.holds.startLabel')} value={holdStart} onChangeText={setHoldStart} mode="outlined" dense style={{ width: 90, backgroundColor: colors.surface }} />
            <TextInput label={t('reservations.holds.endLabel')} value={holdEnd} onChangeText={setHoldEnd} mode="outlined" dense style={{ width: 90, backgroundColor: colors.surface }} />
            <TextInput label={t('reservations.holds.reasonLabel')} value={holdReason} onChangeText={setHoldReason} mode="outlined" dense style={{ flex: 1, minWidth: 160, backgroundColor: colors.surface }} />
            <Button mode="contained" buttonColor={colors.primary} onPress={() => void submitHold()} accessibilityLabel={t('reservations.holds.addButton')}>{t('reservations.holds.addButton')}</Button>
          </View>
          {holdError ? <Text style={{ color: colors.danger, fontSize: 12 }}>{holdError}</Text> : null}
          {(holds ?? []).length === 0 ? (
            <Text style={{ color: colors.muted }}>{t('reservations.holds.empty')}</Text>
          ) : (
            (holds ?? []).map((h) => (
              <View key={h.id} style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.sm, paddingVertical: 6, borderBottomWidth: 1, borderBottomColor: colors.border }}>
                <View style={{ flex: 1 }}>
                  <Text style={{ color: colors.charcoal, fontWeight: '700' }}>{h.reason}</Text>
                  <Text style={{ color: colors.muted, fontSize: 12 }}>
                    {new Date(h.startsAt).toLocaleString()} → {new Date(h.endsAt).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}
                  </Text>
                </View>
                <Button compact mode="text" textColor={colors.danger} onPress={() => void (venue?.id && deleteHold({ venueId: venue.id, holdId: h.id }))}>
                  {t('reservations.holds.remove')}
                </Button>
              </View>
            ))
          )}
          </View>
      </AppCard>

      {/* Waitlist */}
      <AppCard>
          <SectionHeader title={t('reservations.waitlist.title')} />
          <View style={{ gap: spacing.sm }}>
          <View style={{ flexDirection: 'row', gap: spacing.sm, alignItems: 'center' }}>
            <TextInput label={t('reservations.waitlist.nameLabel')} value={wlName} onChangeText={setWlName} mode="outlined" dense style={{ flex: 1, backgroundColor: colors.surface }} />
            <IconButton icon="minus" mode="outlined" size={16} onPress={() => setWlParty((p) => Math.max(1, p - 1))} />
            <Text style={{ minWidth: 20, textAlign: 'center' }}>{wlParty}</Text>
            <IconButton icon="plus" mode="outlined" size={16} onPress={() => setWlParty((p) => Math.min(30, p + 1))} />
          </View>
          <View style={{ flexDirection: 'row', gap: spacing.sm }}>
            <TextInput label={t('reservations.waitlist.phoneLabel')} value={wlPhone} onChangeText={setWlPhone} mode="outlined" dense keyboardType="phone-pad" style={{ flex: 1, backgroundColor: colors.surface }} />
            <TextInput label={t('reservations.waitlist.emailLabel')} value={wlEmail} onChangeText={setWlEmail} mode="outlined" dense autoCapitalize="none" keyboardType="email-address" style={{ flex: 1, backgroundColor: colors.surface }} />
            <Button mode="contained" buttonColor={colors.primary} onPress={() => void addWalkIn()} accessibilityLabel={t('reservations.waitlist.addButton')}>{t('reservations.waitlist.addButton')}</Button>
          </View>
          <Text style={{ color: colors.muted, fontSize: 11 }}>
            {t('reservations.waitlist.hint')}
          </Text>
          {waitlistError ? <Text style={{ color: colors.danger }}>{waitlistError}</Text> : null}
          {waitlist.length === 0 ? (
            <Text style={{ color: colors.muted }}>{t('reservations.waitlist.empty')}</Text>
          ) : (
            waitlist.map((w) => {
              const waitMins = Math.max(0, Math.round((Date.now() - w.requestedAt) / 60000));
              return (
                <View key={w.id} style={{ paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: colors.border, gap: 6 }}>
                  <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                    <Text style={{ fontWeight: '700' }}>{t('reservations.waitlist.entryLine', { name: w.guestName, size: w.partySize })}</Text>
                    {w.readyAt ? <Chip compact style={{ backgroundColor: accents[2].bg }} textStyle={{ color: accents[2].fg }}>{t('reservations.waitlist.ready')}</Chip> : <Text style={{ color: colors.muted }}>{t('reservations.waitlist.waitingMinutes', { minutes: waitMins })}</Text>}
                  </View>
                  <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                    {!w.readyAt ? <Button compact mode="outlined" textColor={accents[2].fg} onPress={() => void handleMarkWaitlistReady(w.id)}>{t('reservations.waitlist.markReady')}</Button> : null}
                    <Button compact mode={seatingWaitlistId === w.id ? 'contained' : 'outlined'} buttonColor={seatingWaitlistId === w.id ? colors.primary : undefined} textColor={seatingWaitlistId === w.id ? '#fff' : colors.primary} onPress={() => setSeatingWaitlistId(seatingWaitlistId === w.id ? null : w.id)}>
                      {seatingWaitlistId === w.id ? t('reservations.waitlist.pickTable') : t('reservations.waitlist.seat')}
                    </Button>
                    <Button compact mode="text" textColor={colors.danger} onPress={() => void handleRemoveFromWaitlist(w.id)}>{t('reservations.waitlist.remove')}</Button>
                  </View>
                  {seatingWaitlistId === w.id ? (
                    <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8, backgroundColor: colors.background, borderRadius: radius.sharp, padding: 10 }}>
                      {openTables.length === 0 ? (
                        <Text style={{ color: colors.danger }}>{t('reservations.waitlist.noOpenTables')}</Text>
                      ) : (
                        recommendedTables(w.partySize).map((t) => (
                          <Chip key={t.table._id} onPress={() => void seatWaitlist(w.id, t.table._id)}>{t.table.label} · {t.table.seats}</Chip>
                        ))
                      )}
                    </View>
                  ) : null}
                </View>
              );
            })
          )}
          </View>
      </AppCard>

      {/* New reservation */}
      {canManage ? (
        <AppCard>
            <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
              <Text style={{ ...type.heading, color: colors.charcoal }}>{t('reservations.form.title')}</Text>
              <View style={{ flexDirection: 'row', gap: spacing.sm }}>
                <Button compact mode={showPrivateEventForm ? 'contained' : 'outlined'} buttonColor={showPrivateEventForm ? colors.primary : undefined} textColor={showPrivateEventForm ? '#fff' : colors.primary} onPress={() => {
                  setShowForm(true);
                  setShowPrivateEventForm((value) => !value);
                  setPartySize((value) => Math.max(value, 20));
                  setTags((value) => (value.includes('private_event') ? value : [value, 'private_event'].filter(Boolean).join(', ')));
                }}>
                  {t('reservations.form.privateEventButton')}
                </Button>
                <Button compact mode={showForm ? 'text' : 'contained'} buttonColor={showForm ? undefined : colors.primary} onPress={() => setShowForm((v) => !v)}>
                  {showForm ? t('reservations.form.closeButton') : t('reservations.form.addButton')}
                </Button>
              </View>
            </View>
            {showForm ? (
              <View style={{ gap: spacing.sm, marginTop: spacing.sm }}>
                <View style={{ flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' }}>
                  <TextInput label={t('reservations.form.firstName')} value={guestFirstName} onChangeText={setGuestFirstName} mode="outlined" style={{ flex: 1, minWidth: 140, backgroundColor: colors.surface }} />
                  <TextInput label={t('reservations.form.lastName')} value={guestLastName} onChangeText={setGuestLastName} mode="outlined" style={{ flex: 1, minWidth: 140, backgroundColor: colors.surface }} />
                </View>
                <View style={{ flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' }}>
                  <TextInput label={t('reservations.form.phone')} value={guestPhone} onChangeText={setGuestPhone} mode="outlined" keyboardType="phone-pad" style={{ flex: 1, minWidth: 145, backgroundColor: colors.surface }} />
                  <TextInput label={t('reservations.form.email')} value={guestEmail} onChangeText={setGuestEmail} mode="outlined" keyboardType="email-address" autoCapitalize="none" style={{ flex: 1, minWidth: 145, backgroundColor: colors.surface }} />
                </View>
                {autofill?.guest ? (
                  <Card style={{ backgroundColor: accents[2].bg, borderRadius: radius.sharp }}>
                    <Card.Content style={{ gap: 4, padding: spacing.sm }}>
                      <Text style={{ color: accents[2].fg, fontWeight: '800' }}>{t('reservations.form.returningGuest.title', { name: autofill.guest.fullName })}</Text>
                      <Text style={{ color: colors.charcoal, fontSize: 12 }}>
                        {autofill.guest.lastVisitAt
                          ? (autofill.guest.lastPartySize
                              ? t('reservations.form.returningGuest.lastVisitWithParty', { date: new Date(autofill.guest.lastVisitAt).toLocaleDateString(), party: autofill.guest.lastPartySize })
                              : t('reservations.form.returningGuest.lastVisit', { date: new Date(autofill.guest.lastVisitAt).toLocaleDateString() }))
                          : t('reservations.form.returningGuest.noPriorVisits')}
                        {autofill.guest.lifecycleStage ? ` · ${autofill.guest.lifecycleStage}` : ''}
                      </Text>
                      {autofill.guest.favoriteTable ? <Text style={{ color: colors.charcoal, fontSize: 12 }}>{t('reservations.form.returningGuest.favoriteTable', { table: autofill.guest.favoriteTable })}</Text> : null}
                      {autofill.guest.preferredServer ? <Text style={{ color: colors.charcoal, fontSize: 12 }}>{t('reservations.form.returningGuest.preferredServer', { server: autofill.guest.preferredServer })}</Text> : null}
                      {autofill.guest.dietaryNotes ? <Text style={{ color: colors.charcoal, fontSize: 12 }}>{t('reservations.form.returningGuest.dietary', { notes: autofill.guest.dietaryNotes })}</Text> : null}
                      <Button compact mode="text" textColor={colors.primary} onPress={() => {
                        const [first, ...rest] = autofill.guest!.fullName.split(' ');
                        setGuestFirstName(first ?? '');
                        setGuestLastName(rest.join(' '));
                      }}>{t('reservations.form.returningGuest.useThisName')}</Button>
                    </Card.Content>
                  </Card>
                ) : null}
                <View style={{ flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' }}>
                  <TextInput label={t('reservations.form.companyLabel')} value={guestCompany} onChangeText={setGuestCompany} mode="outlined" style={{ flex: 1, minWidth: 145, backgroundColor: colors.surface }} />
                  <TextInput label={t('reservations.form.occasionLabel')} value={occasion} onChangeText={setOccasion} mode="outlined" placeholder={t('reservations.form.occasionPlaceholder')} style={{ flex: 1, minWidth: 145, backgroundColor: colors.surface }} />
                </View>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                  <Text style={{ width: 64 }}>{t('reservations.form.partyLabel')}</Text>
                  <IconButton icon="minus" mode="outlined" size={16} onPress={() => setPartySize((p) => Math.max(1, p - 1))} />
                  <Text style={{ minWidth: 28, textAlign: 'center' }}>{partySize}</Text>
                  <IconButton icon="plus" mode="outlined" size={16} onPress={() => setPartySize((p) => Math.min(30, p + 1))} />
                </View>
                <View style={{ flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' }}>
                  <Menu
                    visible={dateMenuOpen}
                    onDismiss={() => setDateMenuOpen(false)}
                    anchor={
                      <Button mode="outlined" onPress={() => setDateMenuOpen(true)} style={{ flex: 1, minWidth: 140 }} contentStyle={{ justifyContent: 'flex-start' }}>
                        {selectedDateOption?.label ?? date}
                      </Button>
                    }
                  >
                    {dateOptions.map((opt) => (
                      <Menu.Item
                        key={opt.value}
                        title={opt.label}
                        onPress={() => {
                          dateTouchedRef.current = true;
                          setDate(opt.value);
                          setDateMenuOpen(false);
                          const meals = getMealsForDayOfWeek(opt.dayOfWeek);
                          const stillValid = meals.some((m) => m.id === selectedMeal);
                          if (!stillValid) {
                            const fallback = opt.dayOfWeek === 0 || opt.dayOfWeek === 6 ? 'brunch' : 'dinner';
                            setSelectedMeal(fallback);
                            setTime(MEAL_TIMES[fallback].time);
                          }
                        }}
                      />
                    ))}
                  </Menu>
                  <TextInput
                    label={t('reservations.form.timeLabel')}
                    value={time}
                    onChangeText={setTime}
                    mode="outlined"
                    placeholder="HH:MM"
                    style={{ width: 90, backgroundColor: colors.surface }}
                  />
                  <Menu
                    visible={mealMenuOpen}
                    onDismiss={() => setMealMenuOpen(false)}
                    anchor={
                      <Button mode="outlined" onPress={() => setMealMenuOpen(true)} style={{ flex: 1, minWidth: 140 }} contentStyle={{ justifyContent: 'flex-start' }}>
                        {MEAL_TIMES[selectedMeal] ? t(`reservations.meals.${selectedMeal}`) : selectedMeal}
                      </Button>
                    }
                  >
                    {availableMeals.map((meal) => {
                      const key = meal.id;
                      return (
                        <Menu.Item
                          key={key}
                          title={`${t(`reservations.meals.${key}`)} · ${meal.time}`}
                          onPress={() => {
                            setSelectedMeal(key);
                            setTime(meal.time);
                            setMealMenuOpen(false);
                          }}
                        />
                      );
                    })}
                  </Menu>
                </View>
                <Text style={{ color: colors.muted, fontSize: 12 }}>
                  {t('reservations.form.mealHint')}
                </Text>
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
                  {reservationSources.map((s) => (
                    <Chip key={s} selected={source === s} onPress={() => setSource(s)}>{s.replace('_', ' ')}</Chip>
                  ))}
                </View>
                {showPrivateEventForm ? (
                  <Card style={{ backgroundColor: accents[5].bg, borderRadius: radius.sharp }}>
                    <Card.Content style={{ gap: spacing.sm }}>
                      <Text variant="titleSmall" style={{ color: accents[5].fg, fontWeight: '800' }}>{t('reservations.privateEvent.title')}</Text>
                      <Text style={{ color: colors.charcoal }}>{t('reservations.privateEvent.subtitle')}</Text>
                      <TextInput label={t('reservations.privateEvent.eventNameLabel')} value={eventName} onChangeText={setEventName} mode="outlined" style={{ backgroundColor: colors.surface }} />
                      <View style={{ flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' }}>
                        <TextInput label={t('reservations.privateEvent.eventSpaceLabel')} value={eventSpace} onChangeText={setEventSpace} mode="outlined" style={{ flex: 1, minWidth: 145, backgroundColor: colors.surface }} />
                        <TextInput label={t('reservations.privateEvent.setupStyleLabel')} value={setupStyle} onChangeText={setSetupStyle} mode="outlined" placeholder={t('reservations.privateEvent.setupStylePlaceholder')} style={{ flex: 1, minWidth: 145, backgroundColor: colors.surface }} />
                      </View>
                      <View style={{ flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' }}>
                        <TextInput label={t('reservations.privateEvent.estimatedValueLabel')} value={estimatedValue} onChangeText={setEstimatedValue} mode="outlined" keyboardType="decimal-pad" style={{ flex: 1, minWidth: 145, backgroundColor: colors.surface }} />
                        <TextInput label={t('reservations.privateEvent.depositDueLabel')} value={depositDue} onChangeText={setDepositDue} mode="outlined" keyboardType="decimal-pad" style={{ flex: 1, minWidth: 145, backgroundColor: colors.surface }} />
                      </View>
                      <TextInput label={t('reservations.privateEvent.menuNotesLabel')} value={menuNotes} onChangeText={setMenuNotes} mode="outlined" multiline style={{ backgroundColor: colors.surface }} />
                      <TextInput label={t('reservations.privateEvent.beverageNotesLabel')} value={beverageNotes} onChangeText={setBeverageNotes} mode="outlined" multiline style={{ backgroundColor: colors.surface }} />
                      <TextInput label={t('reservations.privateEvent.billingNotesLabel')} value={billingNotes} onChangeText={setBillingNotes} mode="outlined" multiline style={{ backgroundColor: colors.surface }} />
                    </Card.Content>
                  </Card>
                ) : null}
                <TextInput label={t('reservations.form.notesLabel')} value={notes} onChangeText={setNotes} mode="outlined" multiline style={{ backgroundColor: colors.surface }} />
                {error ? <Text style={{ color: colors.danger }}>{error}</Text> : null}
                <Button mode="contained" buttonColor={colors.primary} loading={creating} disabled={creating} onPress={() => void createReservation()} accessibilityLabel={t('reservations.form.createButton')}>{t('reservations.form.createButton')}</Button>
              </View>
            ) : null}
        </AppCard>
      ) : null}

      {/* Reservation list */}
      <AppCard>
          <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: spacing.sm }}>
            <Text style={{ ...type.heading, color: colors.charcoal }}>{t('reservations.list.title')}</Text>
            <DateRangeBar selected={listDateRange} presets={listPresets} onSelect={setListDateRange} />
          </View>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6, marginTop: spacing.sm }}>
            {([
              ['all', 'All'], ['now', 'Now'], ['unseated', `Unseated ${unassignedIds.size || ''}`.trim()], ['vip', 'VIP'], ['large', 'Large party'],
            ] as const).map(([value, label]) => (
              <Chip key={value} selected={reservationFilter === value} onPress={() => setReservationFilter(value)}>{label}</Chip>
            ))}
          </View>
          {deleteError ? <Text style={{ color: colors.danger, marginTop: spacing.sm }}>{deleteError}</Text> : null}
          {pageError ? (
            <View style={{ gap: spacing.xs, marginTop: spacing.sm }}>
              <Text style={{ color: colors.danger }}>Failed to load reservations</Text>
              <Button compact mode="outlined" textColor={colors.primary} onPress={() => refetchPage()}>Retry</Button>
            </View>
          ) : pageLoading || page === undefined ? (
            <Text style={{ color: colors.muted, marginTop: spacing.sm }}>{t('reservations.list.loading')}</Text>
          ) : visibleReservations.length === 0 ? (
            <Text style={{ color: colors.muted, marginTop: spacing.sm }}>{t('reservations.list.empty', { range: listDateRange.shortLabel.toLowerCase() })}</Text>
          ) : null}
      </AppCard>
        </>
      )}
        renderItem={({ item: res }) => {
          const sc = statusColor[res.status] ?? { bg: colors.cream, fg: colors.muted };
          const seated = res.status === 'seated';
          const cancelled = res.status === 'cancelled' || res.status === 'no_show' || res.status === 'completed';
          return (
            <View style={{ paddingVertical: 10, paddingHorizontal: spacing.lg, borderBottomWidth: 1, borderBottomColor: colors.border, gap: 6, backgroundColor: colors.surface }}>
              <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                <View>
                  <Text style={{ fontWeight: '800' }}>{formatWeekdayDate(res.reservationTime)}</Text>
                  <Text style={{ color: colors.muted, fontSize: 13 }}>{formatTime(res.reservationTime)}</Text>
                </View>
                <Chip compact style={{ backgroundColor: sc.bg }} textStyle={{ color: sc.fg }}>{res.status.replace('_', ' ')}</Chip>
              </View>
              <Text>{t('reservations.item.partyOf', { name: res.guestName, size: res.partySize })}</Text>
              <Text style={{ color: colors.muted }}>{res.source.replace('_', ' ')}</Text>
              <Button compact mode="text" textColor={colors.primary} onPress={() => setGuestContextId(guestContextId === res.id ? null : res.id)}>
                {guestContextId === res.id ? 'Hide guest context' : 'Guest context'}
              </Button>
              {guestContextId === res.id ? (
                <View style={{ gap: 3, paddingLeft: spacing.sm, borderLeftWidth: 2, borderLeftColor: colors.primary }}>
                  <Text style={{ color: colors.muted, fontSize: 12 }}>{res.guestCompany || 'No company on file'}</Text>
                  <Text style={{ color: colors.muted, fontSize: 12 }}>{res.occasion ? `Occasion: ${res.occasion}` : 'No occasion recorded'}</Text>
                  <Text style={{ color: colors.muted, fontSize: 12 }}>{res.specialRequests || res.notes || 'No service notes recorded'}</Text>
                  {res.tags?.length ? <Text style={{ color: colors.muted, fontSize: 12 }}>Signals: {res.tags.join(' · ')}</Text> : null}
                </View>
              ) : null}
              {res.guestCompany ? <Text style={{ color: colors.muted }}>{res.guestCompany}</Text> : null}
              {res.occasion ? <Chip compact style={{ alignSelf: 'flex-start' }}>{res.occasion}</Chip> : null}
              {res.isPrivateEvent ? (
                <Card style={{ backgroundColor: accents[5].bg, borderRadius: radius.sharp }}>
                  <Card.Content style={{ gap: 4 }}>
                    <Text style={{ color: accents[5].fg, fontWeight: '800' }}>{res.eventName || t('reservations.item.privateEventFallback')}</Text>
                    <Text style={{ color: colors.charcoal }}>{[res.eventSpace, res.setupStyle, res.eventStatus?.replace('_', ' ')].filter(Boolean).join(' ? ') || t('reservations.item.eventDetailsPending')}</Text>
                    {res.estimatedValueCents ? <Text style={{ color: colors.charcoal }}>{t('reservations.item.estimatedValue', { amount: `$${(res.estimatedValueCents / 100).toLocaleString()}` })}</Text> : null}
                  </Card.Content>
                </Card>
              ) : null}

              {res.notes || res.specialRequests ? <Text style={{ color: colors.muted }}>{res.notes ?? res.specialRequests}</Text> : null}
              {res.tags?.length ? (
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
                  {res.tags.map((tag) => (
                    <Chip key={tag} compact>{tag}</Chip>
                  ))}
                </View>
              ) : null}

              {canManage ? (
                <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                  {!seated && !cancelled ? (
                    <Button compact mode={assigningId === res.id ? 'contained' : 'outlined'} buttonColor={assigningId === res.id ? colors.primary : undefined} textColor={assigningId === res.id ? '#fff' : colors.primary} onPress={() => { setAssignError(null); setAssigningId(assigningId === res.id ? null : res.id); }}>
                      {assigningId === res.id ? t('reservations.item.pickTable') : t('reservations.item.assignTable')}
                    </Button>
                  ) : null}
                  <Button compact mode="text" textColor={colors.danger} icon="delete-outline" onPress={() => void deleteReservation(res)}>{t('reservations.item.deleteButton')}</Button>
                </View>
              ) : null}

              {assigningId === res.id ? (
                <View style={{ gap: 6, backgroundColor: colors.background, borderRadius: radius.sharp, padding: 10 }}>
                  <Text style={{ color: colors.muted }}>{t('reservations.item.tapInstructions')}</Text>
                  {assignError ? <Text style={{ color: colors.danger }}>{assignError}</Text> : null}
                  {openTables.length === 0 ? (
                    <Text style={{ color: colors.danger }}>{t('reservations.item.noOpenTablesBuild')}</Text>
                  ) : (
                    <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                      {recommendedTables(res.partySize).map((tbl) => (
                        <View key={tbl.table._id} style={{ gap: 4, alignItems: 'center' }}>
                          <Chip onPress={() => void assignToTable(res, tbl.table._id, false)}>
                            {tbl.table.label} · {tbl.table.seats}
                          </Chip>
                          <Button compact mode="text" textColor={accents[2].fg} onPress={() => void assignToTable(res, tbl.table._id, true)}>{t('reservations.item.seat')}</Button>
                        </View>
                      ))}
                    </View>
                  )}
                </View>
              ) : null}
            </View>
          );
        }}
    />
  );
}
