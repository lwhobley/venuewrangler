import { useCallback, useMemo, useRef, useState } from 'react';
import { Alert, FlatList, Image, ScrollView, Share, View } from 'react-native';
import * as ImagePicker from 'expo-image-picker';
import { router } from 'expo-router';
import * as DocumentPicker from 'expo-document-picker';
import { Button, Card, Chip, Menu, Text, TextInput as PaperTextInput } from 'react-native-paper';
import { ScreenErrorBoundary } from '../../components/ErrorBoundary';
import { useAction, useMutation, useQuery } from '../../lib/railway-hooks';
import { api } from '../../lib/railway-api';
import type { Id } from '../../lib/ids';
import { accents, colors, radius, spacing } from '../../lib/theme';
import { useVenueAuth } from '../../lib/useVenueAuth';
import { errorMessage } from '../../lib/format';
import type { Role } from '../../lib/types';
import { PageHeader } from '../../components/design-system';
import { useI18n } from '../../lib/i18n';
import { readPickedFileText } from '../../lib/picked-file';
import { resolveMediaUrl } from '../../lib/api-client';

type VenueRole = { _id: string; name: string };
type ParsedStaffImportRow = { fullName: string; email: string; phone?: string; jobTitle: string; role: 'manager' | 'staff' };
// Access level = the permission tier an admin/manager assigns when adding a
// teammate. Roles are never self-selected — they are set here on the roster.
type AccessRole = 'manager' | 'staff';

// Job titles / positions, selectable from a dropdown.
const JOB_ROLES = [
  'Manager', 'Asst Manager', 'Supervisor', 'Server', 'Bartender', 'Host',
  'Chef', 'Cook', 'Dishwasher', 'Cleaner', 'Busser', 'Barback', 'Temp', 'Contractor',
];

const CERTIFICATIONS = [
  'TIPS', 'ServSafe', 'Food Handler', 'Alcohol Server', 'CPR/First Aid', 'OSHA',
];

function Dropdown({
  label,
  value,
  placeholder,
  options,
  onSelect,
  style,
}: {
  label?: string;
  value: string;
  placeholder?: string;
  options: Array<{ value: string; label: string }>;
  onSelect: (value: string) => void;
  style?: import('react-native').ViewStyle;
}) {
  const [open, setOpen] = useState(false);
  const current = options.find((o) => o.value === value);
  return (
    <View style={style}>
      {label ? <Text style={{ color: colors.muted, marginBottom: 4 }}>{label}</Text> : null}
      <Menu
        visible={open}
        onDismiss={() => setOpen(false)}
        anchor={
          <Button
            mode="outlined"
            textColor={colors.charcoal}
            onPress={() => setOpen(true)}
            contentStyle={{ flexDirection: 'row-reverse', justifyContent: 'space-between' }}
            icon={() => <Text style={{ color: colors.muted, fontSize: 16, lineHeight: 18 }}>▾</Text>}
            style={{ borderColor: colors.border, justifyContent: 'flex-start' }}
          >
            {current?.label ?? value ?? placeholder ?? 'Select…'}
          </Button>
        }
        contentStyle={{ maxHeight: 280 }}
      >
        <ScrollView style={{ maxHeight: 280 }}>
          {options.map((opt) => (
            <Menu.Item
              key={opt.value}
              title={opt.label}
              onPress={() => {
                onSelect(opt.value);
                setOpen(false);
              }}
            />
          ))}
        </ScrollView>
      </Menu>
    </View>
  );
}

type StaffMember = {
  _id: string;
  fullName: string;
  preferredName: string | null;
  email: string;
  role: Exclude<Role, 'host'>;
  jobTitle: string;
  hourlyRateCents: number | null;
  phone: string | null;
  altPhone: string | null;
  address: string | null;
  dateOfBirth: string | null;
  hireDate: string | null;
  employmentType: string | null;
  emergencyContactName: string | null;
  emergencyContactRelationship: string | null;
  emergencyContactPhone: string | null;
  photoUrl: string | null;
  certifications: string[];
  venueId: string | null;
};

type OnboardingTask = {
  _id: string;
  profileId: string;
  title: string;
  details: string | null;
  category: string;
  status: 'open' | 'done' | 'cancelled';
  completedAt: number | null;
};

type OnboardingStaff = {
  _id: string;
  fullName: string;
  completedCount: number;
  totalCount: number;
  tasks: OnboardingTask[];
};

type OnboardingResponse = { staff: OnboardingStaff[] };

type AuditEntry = {
  _id: string;
  actorName: string | null;
  actorRole: string | null;
  targetName: string | null;
  targetRole: string | null;
  action: string;
  summary: string;
  createdAt: number;
};

export default function StaffScreenWrapper() {
  return <ScreenErrorBoundary><StaffScreen /></ScreenErrorBoundary>;
}

function StaffScreen() {
  const { venue, isReady, me, profileLoading, profileError, refetchProfile, canManage } = useVenueAuth();
  const { t } = useI18n();
  const canElevate = Boolean(me?.profile?.role === 'owner' || me?.profile?.role === 'admin' || me?.profile?.allAccess);
  const ACCESS_LEVELS: Array<{ value: 'admin' | 'manager' | 'staff'; label: string }> = [
    { value: 'admin', label: t('staff.roleAdmin') },
    { value: 'manager', label: t('staff.roleManager') },
    { value: 'staff', label: t('staff.roleStaff') },
  ];
  const LINK_ACCESS_LEVELS: Array<{ value: AccessRole; label: string }> = useMemo(() => [
    ...(canElevate ? [{ value: 'manager' as const, label: t('staff.roleManager') }] : []),
    { value: 'staff' as const, label: t('staff.roleStaff') },
  ], [canElevate, t]);
  const [selectedStaffId, setSelectedStaffId] = useState<string | null>(null);
  const [toolsOpen, setToolsOpen] = useState(false);
  const rosterRef = useRef<FlatList<StaffMember>>(null);
  const [fullName, setFullName] = useState('');
  const [preferredName, setPreferredName] = useState('');
  const [email, setEmail] = useState('');
  const [role, setRole] = useState<Role>('staff');
  const [jobTitle, setJobTitle] = useState('Team Member');
  const [hourlyRate, setHourlyRate] = useState('');
  const [phone, setPhone] = useState('');
  const [altPhone, setAltPhone] = useState('');
  const [address, setAddress] = useState('');
  const [dateOfBirth, setDateOfBirth] = useState('');
  const [hireDate, setHireDate] = useState('');
  const [employmentType, setEmploymentType] = useState('');
  const [emergencyContactName, setEmergencyContactName] = useState('');
  const [emergencyContactRelationship, setEmergencyContactRelationship] = useState('');
  const [emergencyContactPhone, setEmergencyContactPhone] = useState('');
  const [uploadingPhoto, setUploadingPhoto] = useState(false);
  const [certifications, setCertifications] = useState<string[]>([]);

  const staffQuery = useQuery(api.app.listVenueStaff, isReady && venue?.id && canManage ? { venueId: venue.id } : 'skip');
  const staff = useMemo(() => (staffQuery ?? []) as StaffMember[], [staffQuery]);
  const onboardingQuery = useQuery(api.app.listStaffOnboarding, isReady && venue?.id && canManage ? { venueId: venue.id } : 'skip') as OnboardingResponse | null | undefined;
  const auditLogQuery = useQuery(api.app.listStaffAuditLog, isReady && venue?.id && canManage ? { venueId: venue.id } : 'skip') as { entries: AuditEntry[] } | null | undefined;
  const upsertStaff = useMutation(api.app.upsertVenueStaff);
  const uploadStaffPhoto = useMutation(api.app.uploadStaffPhoto);
  const deactivateStaff = useMutation(api.app.deactivateVenueStaff);
  const updateOnboardingTask = useMutation(api.app.updateStaffOnboardingTask);

  // Custom roles + PIN invite
  const rolesQuery = useQuery(api.staffAuth.listVenueRoles, isReady && venue?.id && canManage ? { venueId: venue.id } : 'skip');
  const customRoles = useMemo(() => (rolesQuery ?? []) as VenueRole[], [rolesQuery]);
  // Dropdown options: the standard job titles plus any custom roles the venue added.
  const jobRoleOptions = useMemo(() => {
    const seen = new Set(JOB_ROLES.map((r) => r.toLowerCase()));
    const merged = [...JOB_ROLES];
    for (const r of customRoles) {
      if (!seen.has(r.name.toLowerCase())) {
        merged.push(r.name);
        seen.add(r.name.toLowerCase());
      }
    }
    return merged.map((name) => ({ value: name, label: name }));
  }, [customRoles]);
  const addVenueRole = useMutation(api.staffAuth.addVenueRole);
  const removeVenueRole = useMutation(api.staffAuth.removeVenueRole);

  const createInvite = useMutation(api.invites.createInvite);
  const [inviteLinkRole, setInviteLinkRole] = useState<'manager' | 'staff'>('staff');
  const [inviteLinkPosition, setInviteLinkPosition] = useState('');
  const [inviteLinkMsg, setInviteLinkMsg] = useState<string | null>(null);
  const [inviteLinkErr, setInviteLinkErr] = useState<string | null>(null);
  const [generatingLink, setGeneratingLink] = useState(false);
  const generatingLinkRef = useRef(false);

  const onGenerateInviteLink = async () => {
    if (generatingLinkRef.current || !venue?.id) return;
    generatingLinkRef.current = true;
    setInviteLinkErr(null);
    setInviteLinkMsg(null);
    setGeneratingLink(true);
    try {
      const effectiveRole = canElevate ? inviteLinkRole : 'staff';
      const { inviteUrl } = await createInvite({
        venueId: venue.id,
        role: effectiveRole,
        jobTitle: inviteLinkPosition.trim() || 'Team Member',
      });
      await Share.share({ message: t('staff.shareMessage', { venue: venue.name, url: inviteUrl }) });
      setInviteLinkMsg(t('staff.inviteLinkGenerated'));
    } catch (e) {
      setInviteLinkErr(errorMessage(e, t('staff.inviteLinkError')));
    } finally {
      generatingLinkRef.current = false;
      setGeneratingLink(false);
    }
  };

  // Roster migration: paste an export from any scheduling platform, let the AI
  // normalize it, review the parsed rows, then commit them as staff invites.
  const parseStaffImport = useAction(api.app.parseStaffImport);
  const commitStaffImport = useMutation(api.app.commitStaffImport);
  const [importText, setImportText] = useState('');
  const [importRows, setImportRows] = useState<ParsedStaffImportRow[]>([]);
  const [importBusy, setImportBusy] = useState(false);
  const importBusyRef = useRef(false);
  const submitRef = useRef(false);
  const deactivateRef = useRef(false);
  const [importMsg, setImportMsg] = useState<string | null>(null);
  const [importErr, setImportErr] = useState<string | null>(null);

  const onParseStaffImport = async () => {
    if (!importText.trim()) return;
    setImportErr(null);
    setImportMsg(null);
    setImportBusy(true);
    try {
      const result = await parseStaffImport({ text: importText });
      const items = (result.items ?? []) as ParsedStaffImportRow[];
      setImportRows(items);
      setImportMsg(items.length > 0
        ? t('staff.parsedPeople', { count: items.length, personLabel: items.length === 1 ? t('staff.person') : t('staff.people') })
        : t('staff.noStaffRowsFound'));
    } catch (e) {
      setImportErr(errorMessage(e, t('staff.importParseFailed')));
    } finally {
      setImportBusy(false);
    }
  };

  const onCommitStaffImport = async () => {
    if (importBusyRef.current || !venue?.id || importRows.length === 0) return;
    importBusyRef.current = true;
    setImportErr(null);
    setImportMsg(null);
    setImportBusy(true);
    try {
      const result = await commitStaffImport({ venueId: venue.id, items: importRows });
      const total = result.created + result.updated;
      setImportMsg(
        t('staff.addedUpdated', { created: result.created, updated: result.updated, plural: total === 1 ? '' : 's' }) +
          (result.failed.length > 0 ? t('staff.rowsFailed', { count: result.failed.length, plural: result.failed.length === 1 ? '' : 's' }) : ''),
      );
      setImportRows([]);
      setImportText('');
    } catch (e) {
      setImportErr(errorMessage(e, t('staff.importCommitFailed')));
    } finally {
      importBusyRef.current = false;
      setImportBusy(false);
    }
  };

  const removeImportRow = (index: number) => setImportRows((prev) => prev.filter((_, i) => i !== index));

  const pickImportCsv = async () => {
    setImportErr(null);
    setImportMsg(null);
    setImportBusy(true);
    try {
      const doc = await DocumentPicker.getDocumentAsync({ type: ['text/*', 'text/csv', 'application/csv'], copyToCacheDirectory: true });
      if (doc.canceled || !doc.assets[0]?.uri) return;
      const text = await readPickedFileText(doc.assets[0]);
      setImportText(text);
      setImportMsg(t('staff.csvLoaded', { name: doc.assets[0].name ?? 'upload' }));
    } catch (e) {
      setImportErr(errorMessage(e, t('staff.csvLoadFailed')));
    } finally {
      setImportBusy(false);
    }
  };

  const [newRole, setNewRole] = useState('');

  const onAddRole = async () => {
    if (!venue?.id || !newRole.trim()) return;
    try {
      await addVenueRole({ venueId: venue.id, name: newRole.trim() });
      setNewRole('');
    } catch {
      // ignore (duplicate)
    }
  };

  const selectedStaff = staff.find((member: StaffMember) => member._id === selectedStaffId) ?? null;
  const onboardingRows = onboardingQuery?.staff ?? [];
  const selectedOnboarding = selectedStaffId
    ? onboardingRows.find((row) => row._id === selectedStaffId) ?? null
    : null;
  const auditEntries = auditLogQuery?.entries ?? [];
  const onboardingProgress = selectedOnboarding && selectedOnboarding.totalCount > 0
    ? Math.round((selectedOnboarding.completedCount / selectedOnboarding.totalCount) * 100)
    : 0;

  const fillFromStaff = (member: StaffMember) => {
    setToolsOpen(true);
    rosterRef.current?.scrollToOffset({ offset: 0, animated: true });
    setSelectedStaffId(member._id);
    setFullName(member.fullName);
    setPreferredName(member.preferredName ?? '');
    setEmail(member.email);
    setRole(member.role);
    setJobTitle(member.jobTitle);
    setHourlyRate(member.hourlyRateCents == null ? '' : (member.hourlyRateCents / 100).toFixed(2));
    setPhone(member.phone ?? '');
    setAltPhone(member.altPhone ?? '');
    setAddress(member.address ?? '');
    setDateOfBirth(member.dateOfBirth?.slice(0, 10) ?? '');
    setHireDate(member.hireDate?.slice(0, 10) ?? '');
    setEmploymentType(member.employmentType ?? '');
    setEmergencyContactName(member.emergencyContactName ?? '');
    setEmergencyContactRelationship(member.emergencyContactRelationship ?? '');
    setEmergencyContactPhone(member.emergencyContactPhone ?? '');
    setCertifications(member.certifications ?? []);
  };

  const clearForm = () => {
    setSelectedStaffId(null);
    setFullName('');
    setPreferredName('');
    setEmail('');
    setRole('staff');
    setJobTitle('Team Member');
    setHourlyRate('');
    setPhone('');
    setAltPhone('');
    setAddress('');
    setDateOfBirth('');
    setHireDate('');
    setEmploymentType('');
    setEmergencyContactName('');
    setEmergencyContactRelationship('');
    setEmergencyContactPhone('');
    setCertifications([]);
  };

  const onSubmit = async () => {
    // Without a synchronous guard a double-tap created two profiles with the
    // same name and email (staffId is undefined on the create path).
    if (submitRef.current || !venue?.id || !canManage) return;
    if (hourlyRate.trim() && (!/^\d+(\.\d{1,2})?$/.test(hourlyRate.trim()) || Number(hourlyRate) > 10000)) {
      Alert.alert('Invalid hourly rate', 'Enter an amount such as 18.50.');
      return;
    }
    submitRef.current = true;
    try {
      await upsertStaff({
        venueId: venue.id,
        staffId: selectedStaffId ?? undefined,
        fullName,
        preferredName: preferredName.trim(),
        email,
        role,
        jobTitle,
        // `null` clears a previously-saved value; `undefined` would omit the key entirely
        // and the API preserves whatever was already saved — so a blank field here must be
        // sent as null, not undefined, or clearing it in the UI silently does nothing.
        hourlyRateCents: hourlyRate.trim() ? Math.round(Number(hourlyRate.trim()) * 100) : null,
        phone: phone.trim() || null,
        altPhone: altPhone.trim() || null,
        address: address.trim() || null,
        dateOfBirth: dateOfBirth.trim() || null,
        hireDate: hireDate.trim() || null,
        employmentType: employmentType || null,
        emergencyContactName: emergencyContactName.trim(),
        emergencyContactRelationship: emergencyContactRelationship.trim(),
        emergencyContactPhone: emergencyContactPhone.trim(),
        certifications,
      });
      clearForm();
    } catch (e) {
      Alert.alert(t('staff.errorTitle'), errorMessage(e, t('staff.saveFailed')));
    } finally {
      submitRef.current = false;
    }
  };

  const pickStaffPhoto = async (member: StaffMember) => {
    const result = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ImagePicker.MediaTypeOptions.Images, allowsEditing: true, quality: 0.7, base64: true });
    const asset = result.canceled ? null : result.assets[0];
    if (!asset?.base64) return;
    setUploadingPhoto(true);
    try {
      await uploadStaffPhoto({ staffId: member._id, dataBase64: asset.base64, mimeType: asset.mimeType ?? 'image/jpeg' });
    } catch (error) {
      Alert.alert('Photo upload failed', errorMessage(error, 'Please try again.'));
    } finally {
      setUploadingPhoto(false);
    }
  };

  const onDeactivate = async (member: StaffMember) => {
    if (!canManage) return;
    Alert.alert(t('staff.deactivateConfirmTitle'), t('staff.deactivateConfirmMessage', { name: member.fullName }), [
      { text: t('staff.cancel'), style: 'cancel' },
      { text: t('staff.deactivate'), style: 'destructive', onPress: async () => {
        if (deactivateRef.current) return;
        deactivateRef.current = true;
        try {
          await deactivateStaff({ staffId: member._id as Id<'profiles'> });
          if (selectedStaffId === member._id) clearForm();
        } catch (e) {
          Alert.alert(t('staff.errorTitle'), errorMessage(e, t('staff.actionFailed')));
        } finally {
          deactivateRef.current = false;
        }
      }}
    ]);
  };

  const setOnboardingStatus = async (task: OnboardingTask, status: 'open' | 'done') => {
    try {
      await updateOnboardingTask({ taskId: task._id, status });
    } catch (e) {
      Alert.alert(t('staff.errorTitle'), errorMessage(e, t('staff.onboardingUpdateFailed')));
    }
  };

  if (profileLoading) {
    return (
      <View style={{ flex: 1, backgroundColor: colors.background, padding: spacing.lg, justifyContent: 'center' }}>
        <Text style={{ color: colors.muted }}>{t('staff.loading')}</Text>
      </View>
    );
  }
  if (profileError) {
    return (
      <View style={{ flex: 1, backgroundColor: colors.background, padding: spacing.lg, justifyContent: 'center', gap: spacing.sm }}>
        <Text style={{ color: colors.muted }}>Couldn't load your profile. Check your connection and try again.</Text>
        <Button mode="outlined" onPress={() => refetchProfile()}>
          Retry
        </Button>
      </View>
    );
  }
  if (!canManage) {
    return (
      <View style={{ flex: 1, backgroundColor: colors.background, padding: spacing.lg, justifyContent: 'center' }}>
        <Card style={{ backgroundColor: colors.surface }}>
          <Card.Content style={{ gap: 8 }}>
            <Text variant="headlineSmall">{t('staff.managementTitle')}</Text>
            <Text style={{ color: colors.muted }}>{t('staff.managementRestricted')}</Text>
          </Card.Content>
        </Card>
      </View>
    );
  }

  return (
    <FlatList
      ref={rosterRef}
      data={staff}
      keyExtractor={(item) => item._id}
      style={{ flex: 1, backgroundColor: colors.background }}
      contentContainerStyle={{ flexGrow: 1, padding: spacing.lg, gap: spacing.md }}
      removeClippedSubviews
      ListHeaderComponent={(
        <>
      <PageHeader
        kicker={t('staff.kicker')}
        title={t('staff.managementTitle')}
        detail={t('staff.subtitle', { venue: venue?.name ?? t('common.yourVenue') })}
        action={
          <Button
            mode="outlined"
            icon="account-check"
            textColor={colors.primary}
            onPress={() => router.push('/join-requests')}
          >
            {t('staff.joinRequests')}
          </Button>
        }
      />

      <Button mode="contained" buttonColor={colors.primary} icon={toolsOpen ? 'chevron-up' : 'account-plus-outline'} accessibilityState={{ expanded: toolsOpen }} onPress={() => setToolsOpen((open) => !open)} style={{ borderRadius: radius.pill, marginBottom: spacing.sm }} contentStyle={{ minHeight: 48 }}>
        {toolsOpen ? 'Close team tools' : 'Add New Staff'}
      </Button>
      <View style={{ display: toolsOpen ? 'flex' : 'none', gap: spacing.md }}>
      <Card style={{ backgroundColor: colors.surface }}>
        <Card.Content style={{ gap: spacing.sm }}>
          <Text variant="titleMedium">{t('staff.addByEmailTitle')}</Text>
          <Text style={{ color: colors.muted }}>
            {t('staff.addByEmailSubtitle', { venue: venue?.name ?? t('common.yourVenue') })}
          </Text>
          <PaperTextInput placeholder={t('staff.fullNamePlaceholder')} value={fullName} onChangeText={setFullName} mode="outlined" style={{ backgroundColor: colors.surface }} />
          <PaperTextInput label="Preferred name" value={preferredName} onChangeText={setPreferredName} mode="outlined" style={{ backgroundColor: colors.surface }} />
          <PaperTextInput placeholder={t('staff.emailPlaceholder')} value={email} onChangeText={setEmail} keyboardType="email-address" autoCapitalize="none" mode="outlined" style={{ backgroundColor: colors.surface }} />
          <Dropdown
            label={t('staff.accessLevel')}
            value={role}
            options={ACCESS_LEVELS}
            onSelect={(v) => setRole(v as Role)}
          />
          <Dropdown
            label={t('staff.roleLabel')}
            value={jobTitle}
            placeholder={t('staff.selectRole')}
            options={jobRoleOptions}
            onSelect={setJobTitle}
          />
          <PaperTextInput label="Hourly rate ($)" value={hourlyRate} onChangeText={setHourlyRate} keyboardType="decimal-pad" mode="outlined" style={{ backgroundColor: colors.surface }} />
          <PaperTextInput placeholder={t('staff.phonePlaceholder')} value={phone} onChangeText={setPhone} keyboardType="phone-pad" mode="outlined" style={{ backgroundColor: colors.surface }} />
          <PaperTextInput placeholder={t('staff.altPhonePlaceholder')} value={altPhone} onChangeText={setAltPhone} keyboardType="phone-pad" mode="outlined" style={{ backgroundColor: colors.surface }} />
          <PaperTextInput placeholder={t('staff.addressPlaceholder')} value={address} onChangeText={setAddress} mode="outlined" style={{ backgroundColor: colors.surface }} />
          <PaperTextInput placeholder={t('staff.dobPlaceholder')} value={dateOfBirth} onChangeText={setDateOfBirth} mode="outlined" style={{ backgroundColor: colors.surface }} />
          <PaperTextInput label="Hire date (YYYY-MM-DD)" value={hireDate} onChangeText={setHireDate} mode="outlined" style={{ backgroundColor: colors.surface }} />
          <Dropdown label="Employment type" value={employmentType} placeholder="Select employment type" options={[
            { value: 'full_time', label: 'Full time' }, { value: 'part_time', label: 'Part time' },
            { value: 'seasonal', label: 'Seasonal' }, { value: 'contractor', label: 'Contractor' },
            { value: 'temporary', label: 'Temporary' },
          ]} onSelect={setEmploymentType} />
          <PaperTextInput label="Emergency contact name" value={emergencyContactName} onChangeText={setEmergencyContactName} mode="outlined" style={{ backgroundColor: colors.surface }} />
          <PaperTextInput label="Emergency contact relationship" value={emergencyContactRelationship} onChangeText={setEmergencyContactRelationship} mode="outlined" style={{ backgroundColor: colors.surface }} />
          <PaperTextInput label="Emergency contact phone" value={emergencyContactPhone} onChangeText={setEmergencyContactPhone} keyboardType="phone-pad" mode="outlined" style={{ backgroundColor: colors.surface }} />
          {selectedStaff ? <Button mode="outlined" icon="camera-outline" loading={uploadingPhoto} disabled={uploadingPhoto} onPress={() => void pickStaffPhoto(selectedStaff)}>Upload {selectedStaff.preferredName || selectedStaff.fullName}'s photo</Button> : null}
          <View style={{ gap: 4 }}>
            <Text style={{ color: colors.muted }}>{t('staff.certifications')}</Text>
            <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
              {CERTIFICATIONS.map((cert) => (
                <Chip
                  key={cert}
                  selected={certifications.includes(cert)}
                  onPress={() =>
                    setCertifications((prev) =>
                      prev.includes(cert) ? prev.filter((c) => c !== cert) : [...prev, cert],
                    )
                  }
                >
                  {cert}
                </Chip>
              ))}
            </View>
          </View>
          <Button mode="contained" buttonColor={colors.primary} onPress={() => void onSubmit()} accessibilityLabel={selectedStaff ? t('staff.updateStaffMember') : t('staff.addStaffMember')}>
            {selectedStaff ? t('staff.updateStaffMember') : t('staff.addStaffMember')}
          </Button>
          {selectedStaff ? (
            <Button mode="text" textColor={colors.primary} onPress={clearForm}>
              {t('staff.clearSelection')}
            </Button>
          ) : null}
        </Card.Content>
      </Card>

      {/* Roles / positions */}
      <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}>
        <Card.Content style={{ gap: spacing.sm }}>
          <Text variant="titleMedium" style={{ fontWeight: '700' }}>{t('staff.rolesTitle')}</Text>
          <Text style={{ color: colors.muted }}>{t('staff.rolesSubtitle')}</Text>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
            {customRoles.length === 0 ? (
              <Text style={{ color: colors.muted }}>{t('staff.noCustomRoles')}</Text>
            ) : (
              customRoles.map((r) => (
                <Chip key={r._id} onClose={() => venue?.id && void removeVenueRole({ venueId: venue.id, roleId: r._id as Id<'venueRoles'> })}>
                  {r.name}
                </Chip>
              ))
            )}
          </View>
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <PaperTextInput placeholder={t('staff.newRolePlaceholder')} value={newRole} onChangeText={setNewRole} mode="outlined" style={{ flex: 1, backgroundColor: colors.surface }} />
            <Button mode="contained" buttonColor={colors.primary} onPress={() => void onAddRole()}>{t('staff.addRole')}</Button>
          </View>
        </Card.Content>
      </Card>

      {/* Invite staff via link (primary) */}
      <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}>
        <Card.Content style={{ gap: spacing.sm }}>
          <Text variant="titleMedium" style={{ fontWeight: '700' }}>{t('staff.inviteLinkTitle')}</Text>
          <Text style={{ color: colors.muted }}>{t('staff.inviteLinkSubtitle', { venue: venue?.name ?? t('common.yourVenue') })}</Text>
          <Dropdown
            label={t('staff.accessLevel')}
            value={inviteLinkRole}
            options={LINK_ACCESS_LEVELS}
            onSelect={(v) => setInviteLinkRole(v as 'manager' | 'staff')}
          />
          <Dropdown
            label={t('staff.rolePosition')}
            value={inviteLinkPosition}
            placeholder={t('staff.selectRole')}
            options={jobRoleOptions}
            onSelect={setInviteLinkPosition}
          />
          {inviteLinkErr ? <Text style={{ color: colors.danger }}>{inviteLinkErr}</Text> : null}
          {inviteLinkMsg ? <Text style={{ color: accents[2].fg }}>{inviteLinkMsg}</Text> : null}
          <Button mode="contained" buttonColor={colors.primary} icon="link-variant" loading={generatingLink} disabled={generatingLink} onPress={() => void onGenerateInviteLink()} accessibilityLabel={t('staff.generateShareLink')}>
            {t('staff.generateShareLink')}
          </Button>
        </Card.Content>
      </Card>

      <Card style={{ backgroundColor: colors.surface }}>
        <Card.Content style={{ gap: spacing.sm }}>
          <Text variant="titleMedium">{t('staff.migrateTitle')}</Text>
          <Text style={{ color: colors.muted }}>
            {t('staff.migrateSubtitle')}
          </Text>
          <PaperTextInput
            placeholder={t('staff.pasteRosterPlaceholder')}
            value={importText}
            onChangeText={setImportText}
            mode="outlined"
            multiline
            numberOfLines={5}
            style={{ backgroundColor: colors.surface, minHeight: 110 }}
          />
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm }}>
            <Button
              mode="contained"
              buttonColor={colors.primary}
              loading={importBusy}
              disabled={importBusy || !importText.trim()}
              onPress={() => void onParseStaffImport()}
            >
              {t('staff.parseRoster')}
            </Button>
            <Button mode="outlined" textColor={colors.primary} disabled={importBusy} onPress={() => void pickImportCsv()}>
              {t('staff.uploadCsv')}
            </Button>
          </View>
          {importRows.length > 0 ? (
            <View style={{ gap: spacing.sm }}>
              <Text style={{ fontWeight: '700' }}>{t('staff.reviewBeforeImport', { count: importRows.length })}</Text>
              {importRows.map((row, index) => (
                <View
                  key={`${row.email}-${index}`}
                  style={{ borderTopWidth: 1, borderTopColor: colors.border, paddingTop: spacing.sm, flexDirection: 'row', alignItems: 'center', gap: spacing.sm }}
                >
                  <View style={{ flex: 1 }}>
                    <Text style={{ fontWeight: '700' }}>{row.fullName}</Text>
                    <Text style={{ color: colors.muted }}>{row.email} · {row.jobTitle} · {row.role}</Text>
                  </View>
                  <Button mode="text" textColor={colors.muted} compact onPress={() => removeImportRow(index)}>
                    {t('staff.remove')}
                  </Button>
                </View>
              ))}
              <Button mode="contained" buttonColor={colors.primary} loading={importBusy} disabled={importBusy} onPress={() => void onCommitStaffImport()}>
                {t('staff.addStaffCount', { count: importRows.length, plural: importRows.length === 1 ? '' : 's' })}
              </Button>
            </View>
          ) : null}
          {importErr ? <Text style={{ color: colors.danger }}>{importErr}</Text> : null}
          {importMsg ? <Text style={{ color: accents[2].fg }}>{importMsg}</Text> : null}
        </Card.Content>
      </Card>

      {selectedStaff ? (
        <Card style={{ backgroundColor: colors.surface }}>
          <Card.Content style={{ gap: spacing.sm }}>
            <Text variant="titleMedium">{t('staff.deactivateTitle')}</Text>
            <Text style={{ color: colors.muted }}>
              {t('staff.deactivateDesc')}
            </Text>
            <Text style={{ fontWeight: '700' }}>{selectedStaff.fullName}</Text>
            <Text style={{ color: colors.muted }}>{selectedStaff.email}</Text>
            <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
              <Button mode="contained" buttonColor={colors.primary} onPress={() => void onDeactivate(selectedStaff)}>
                {t('staff.deactivate')}
              </Button>
            </View>
          </Card.Content>
        </Card>
      ) : null}

      <Card style={{ backgroundColor: colors.surface }}>
        <Card.Content style={{ gap: spacing.sm }}>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'space-between', gap: spacing.sm }}>
            <View style={{ flex: 1, minWidth: 220 }}>
              <Text variant="titleMedium">{t('staff.onboardingTitle')}</Text>
              <Text style={{ color: colors.muted }}>
                {t('staff.onboardingSubtitle')}
              </Text>
            </View>
            {selectedOnboarding ? (
              <Chip compact style={{ backgroundColor: onboardingProgress === 100 ? accents[2].bg : accents[1].bg }}>
                {t('staff.onboardingProgress', { completed: selectedOnboarding.completedCount, total: selectedOnboarding.totalCount })}
              </Chip>
            ) : null}
          </View>

          {!selectedStaff ? (
            <Text style={{ color: colors.muted }}>{t('staff.onboardingChooseStaff')}</Text>
          ) : !selectedOnboarding ? (
            <Text style={{ color: colors.muted }}>{t('staff.onboardingLoading')}</Text>
          ) : (
            <View style={{ gap: spacing.sm }}>
              <Text style={{ fontWeight: '700' }}>{selectedOnboarding.fullName}</Text>
              <View style={{ height: 6, backgroundColor: colors.border, borderRadius: 999, overflow: 'hidden' }}>
                <View style={{ height: 6, width: `${onboardingProgress}%`, backgroundColor: onboardingProgress === 100 ? accents[2].fg : colors.primary }} />
              </View>
              {selectedOnboarding.tasks.filter((task) => task.status !== 'cancelled').map((task) => (
                <View key={task._id} style={{ borderTopWidth: 1, borderTopColor: colors.border, paddingTop: spacing.sm, gap: 4 }}>
                  <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start', gap: spacing.sm }}>
                    <View style={{ flex: 1 }}>
                      <Text style={{ fontWeight: '700', textDecorationLine: task.status === 'done' ? 'line-through' : 'none' }}>{task.title}</Text>
                      {task.details ? <Text style={{ color: colors.muted, fontSize: 12 }}>{task.details}</Text> : null}
                      <Text style={{ color: colors.muted, fontSize: 12 }}>
                        {task.completedAt
                          ? t('staff.taskCompleted', { category: task.category, date: new Date(task.completedAt).toLocaleDateString() })
                          : task.category}
                      </Text>
                    </View>
                    <Button
                      compact
                      mode={task.status === 'done' ? 'outlined' : 'contained'}
                      buttonColor={task.status === 'done' ? undefined : colors.primary}
                      textColor={task.status === 'done' ? colors.primary : undefined}
                      onPress={() => void setOnboardingStatus(task, task.status === 'done' ? 'open' : 'done')}
                    >
                      {task.status === 'done' ? t('staff.reopen') : t('staff.done')}
                    </Button>
                  </View>
                </View>
              ))}
            </View>
          )}
        </Card.Content>
      </Card>

      <Card style={{ backgroundColor: colors.surface }}>
        <Card.Content style={{ gap: spacing.sm }}>
          <Text variant="titleMedium">{t('staff.auditLogTitle')}</Text>
          <Text style={{ color: colors.muted }}>
            {t('staff.auditLogSubtitle')}
          </Text>
          {auditEntries.length === 0 ? (
            <Text style={{ color: colors.muted }}>{t('staff.noAuditEntries')}</Text>
          ) : (
            auditEntries.slice(0, 8).map((entry) => (
              <View key={entry._id} style={{ borderTopWidth: 1, borderTopColor: colors.border, paddingTop: spacing.sm, gap: 4 }}>
                <Text style={{ fontWeight: '700' }}>{entry.summary}</Text>
                <Text style={{ color: colors.muted, fontSize: 12 }}>
                  {new Date(entry.createdAt).toLocaleString()} - {entry.actorName ?? 'System'} ({entry.actorRole ?? 'unknown'})
                  {entry.targetName ? ` -> ${entry.targetName} (${entry.targetRole ?? 'unknown'})` : ''}
                </Text>
                <Chip compact style={{ alignSelf: 'flex-start' }}>{entry.action.replace(/_/g, ' ')}</Chip>
              </View>
            ))
          )}
        </Card.Content>
      </Card>

      </View>
      <Card style={{ backgroundColor: colors.surface }}>
        <Card.Content style={{ gap: spacing.sm }}>
          <Text variant="titleMedium" style={{ fontWeight: '700', color: colors.charcoal }}>Team roster · {staff.length}</Text>
          {staff.length === 0 ? (
            <Text style={{ color: colors.muted }}>{t('staff.noStaffYet')}</Text>
          ) : null}
        </Card.Content>
      </Card>
        </>
      )}
        renderItem={({ item: member }) => (
          <View
            style={{
              gap: 8,
              padding: spacing.md,
              backgroundColor: member._id === selectedStaffId ? colors.cream : colors.surface,
              borderWidth: 1,
              borderColor: member._id === selectedStaffId ? colors.primary : colors.border,
              borderRadius: radius.lg,
              marginBottom: 4,
            }}
          >
            <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', gap: 12 }}>
              {member.photoUrl ? <Image source={{ uri: resolveMediaUrl(member.photoUrl) }} style={{ width: 42, height: 42, borderRadius: 21 }} /> : <View style={{ width: 38, height: 38, borderRadius: 19, backgroundColor: colors.surfaceSoft, alignItems: 'center', justifyContent: 'center' }}>
                <Text style={{ color: colors.primary, fontWeight: '800' }}>{member.fullName.split(/\s+/).slice(0, 2).map((part) => part[0] ?? '').join('').toUpperCase()}</Text>
              </View>}
              <View style={{ flex: 1, gap: 1 }}>
                <Text style={{ fontWeight: '700', color: colors.charcoal }}>{member.preferredName || member.fullName}</Text>
                <Text style={{ color: colors.muted, fontSize: 12 }}>{member.jobTitle} · {member.email}</Text>
              </View>
              <Button compact mode="text" icon="pencil-outline" textColor={colors.primary} onPress={() => { fillFromStaff(member); setToolsOpen(true); rosterRef.current?.scrollToOffset({ offset: 0, animated: true }); }}>{t('staff.edit')}</Button>
            </View>
            <Chip compact style={{ alignSelf: 'flex-start', backgroundColor: colors.surfaceSoft }} textStyle={{ color: colors.primary }}>{member.role}</Chip>
            {member.phone ? <Text style={{ color: colors.muted, fontSize: 12 }}>{t('staff.phoneLabelValue', { phone: member.phone })}</Text> : null}
            {member.dateOfBirth ? <Text style={{ color: colors.muted, fontSize: 12 }}>{t('staff.dobLabelValue', { dob: member.dateOfBirth })}</Text> : null}
            {member.certifications?.length > 0 ? (
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 4 }}>
                {member.certifications.map((c) => <Chip key={c} compact>{c}</Chip>)}
              </View>
            ) : null}
            {selectedStaffId === member._id ? <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
              <Button mode="outlined" onPress={() => void onDeactivate(member)}>
                {t('staff.deactivate')}
              </Button>
              <Button mode="text" textColor={colors.primary} onPress={clearForm}>
                {t('staff.deselect')}
              </Button>
            </View> : null}
          </View>
        )}
    />
  );
}
