import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

function doc(overrides: Record<string, unknown> = {}) {
  return {
    id: 'd1', title: 'Opening Checklist', fileName: 'opening.pdf', category: 'sop', mimeType: 'application/pdf',
    sizeBytes: 2048, uploadedBy: 'Casey', createdAt: Date.UTC(2026, 8, 1),
    ...overrides,
  };
}

const state = vi.hoisted(() => ({
  venue: { id: 'venue-1', name: 'The Fox & Vine' } as any,
  canManage: true,
  profileLoading: false,
  documents: undefined as any,
  docsError: null as unknown,
  uploadDocument: vi.fn(),
  accessDocument: vi.fn(),
  removeDocument: vi.fn(),
  pickedFile: null as any,
  openURL: vi.fn(),
  alert: vi.fn(),
  refetch: vi.fn(),
}));

vi.mock('react-native', () => ({ Alert: { alert: state.alert }, Linking: { openURL: state.openURL }, ScrollView: 'ScrollView', View: 'View' }));
vi.mock('expo-document-picker', () => ({ getDocumentAsync: vi.fn(() => Promise.resolve(state.pickedFile)) }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return {
    ActivityIndicator: element('ActivityIndicator'), Button: element('Button'), Card, Chip: element('Chip'),
    Searchbar: element('Searchbar'), Text: element('Text'), TextInput: element('TextInput'),
  };
});
vi.mock('@expo/vector-icons', () => ({ MaterialCommunityIcons: 'MaterialCommunityIcons' }));
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../components/InlineMessage', () => ({ InlineMessage: ({ message }: any) => message }));
vi.mock('../../components/AppCard', () => ({ SectionHeader: ({ title }: any) => title }));
vi.mock('../../lib/useVenueAuth', () => ({
  useVenueAuth: () => ({ venue: state.venue, isReady: true, canManage: state.canManage, profileLoading: state.profileLoading }),
}));
vi.mock('../../lib/picked-file', () => ({ readPickedFileBase64: vi.fn(() => Promise.resolve('base64data')) }));
vi.mock('../../lib/railway-api', () => ({
  api: { documents: { list: 'list', upload: 'upload', access: 'access', remove: 'remove' } },
}));
vi.mock('../../lib/railway-hooks', () => ({
  useQueryState: () => ({ data: state.documents, error: state.docsError, isLoading: false, refetch: state.refetch }),
  useMutation: (ref: string) => (ref === 'upload' ? state.uploadDocument : ref === 'access' ? state.accessDocument : ref === 'remove' ? state.removeDocument : vi.fn()),
}));
vi.mock('../../lib/theme', () => ({
  radius: { sharp: 4 },
  spacing: { lg: 24, md: 16, sm: 8, xl: 32, xxxl: 64 },
  useDesignTheme: () => ({ background: '#000', border: '#333', charcoal: '#222', danger: '#f00', muted: '#777', primary: '#0f0', surface: '#111', surfaceSoft: '#191919' }),
}));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
    formatDate: (ts: number) => `date${ts}`,
  }),
}));

import DocumentsScreen from '../../app/(tabs)/documents';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Documents screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.venue = { id: 'venue-1', name: 'The Fox & Vine' };
    state.canManage = true;
    state.profileLoading = false;
    state.documents = [];
    state.docsError = null;
    state.pickedFile = { canceled: false, assets: [{ uri: 'file://x', name: 'Opening.pdf', mimeType: 'application/pdf', size: 1024 }] };
  });

  it('blocks upload without a chosen file', async () => {
    const r = render();
    await act(async () => r.render(<DocumentsScreen />));
    await act(async () => buttonByLabel(r, 'documents.upload')?.props.onPress());
    expect(state.uploadDocument).not.toHaveBeenCalled();
    expect(output(r)).toContain('documents.errors.fileRequired');
  });

  it('picks a file, derives a title, and uploads with base64 content', async () => {
    state.uploadDocument.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<DocumentsScreen />));
    await act(async () => buttonByLabel(r, 'documents.chooseFile')?.props.onPress());
    expect(output(r)).toContain('Opening.pdf');

    await act(async () => buttonByLabel(r, 'documents.upload')?.props.onPress());
    expect(state.uploadDocument).toHaveBeenCalledWith(expect.objectContaining({
      title: 'Opening', fileName: 'Opening.pdf', mimeType: 'application/pdf', category: 'sop', dataBase64: 'base64data',
    }));
  });

  it('rejects a file over the 10MB limit before it can be uploaded', async () => {
    state.pickedFile = { canceled: false, assets: [{ uri: 'file://big', name: 'huge.pdf', mimeType: 'application/pdf', size: 11 * 1024 * 1024 }] };
    const r = render();
    await act(async () => r.render(<DocumentsScreen />));
    await act(async () => buttonByLabel(r, 'documents.chooseFile')?.props.onPress());
    expect(output(r)).toContain('documents.errors.tooLarge');
    expect(output(r)).not.toContain('huge.pdf');
  });

  it('hides the uploader from staff without manage permission', async () => {
    state.canManage = false;
    const r = render();
    await act(async () => r.render(<DocumentsScreen />));
    expect(output(r)).not.toContain('documents.uploadTitle');
    expect(output(r)).toContain('documents.managerHint');
  });

  it('opens a document through the signed access URL', async () => {
    state.documents = [doc()];
    state.accessDocument.mockResolvedValueOnce({ url: 'https://files.example.com/opening.pdf?sig=abc' });
    const r = render();
    await act(async () => r.render(<DocumentsScreen />));
    await act(async () => buttonByLabel(r, 'documents.open')?.props.onPress());
    expect(state.accessDocument).toHaveBeenCalledWith({ documentId: 'd1' });
    expect(state.openURL).toHaveBeenCalledWith('https://files.example.com/opening.pdf?sig=abc');
  });

  it('confirms before deleting a document', async () => {
    state.documents = [doc()];
    state.removeDocument.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<DocumentsScreen />));
    await act(async () => buttonByLabel(r, 'documents.delete')?.props.onPress());
    expect(state.alert).toHaveBeenCalled();
    expect(state.removeDocument).not.toHaveBeenCalled();
    const buttons = state.alert.mock.calls[0][2];
    const confirm = buttons.find((b: any) => b.style === 'destructive');
    await act(async () => confirm.onPress());
    expect(state.removeDocument).toHaveBeenCalledWith({ documentId: 'd1' });
  });

  it('filters the library by search text across title, filename, and uploader', async () => {
    state.documents = [doc({ id: 'd1', title: 'Opening Checklist' }), doc({ id: 'd2', title: 'Wine List', fileName: 'wine.pdf' })];
    const r = render();
    await act(async () => r.render(<DocumentsScreen />));
    const searchbar = r.container.queryAll((n) => n.type === 'Searchbar')[0];
    await act(async () => searchbar?.props.onChangeText('wine'));
    const out = output(r);
    expect(out).toContain('Wine List');
    expect(out).not.toContain('Opening Checklist');
  });

  it('shows a retry action when the document list fails to load', async () => {
    state.docsError = new Error('offline');
    const r = render();
    await act(async () => r.render(<DocumentsScreen />));
    await act(async () => buttonByLabel(r, 'documents.retry')?.props.onPress());
    expect(state.refetch).toHaveBeenCalled();
  });
});
