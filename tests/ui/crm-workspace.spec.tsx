import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { CrmSalesWorkspace } from '../../components/CrmSalesWorkspace';

const state = vi.hoisted(() => ({
  leads: [
    {
      _id: 'lead-1',
      fullName: 'Big Corp Gala',
      company: 'Acme Corp',
      email: 'acme@example.com',
      phone: '555-1234',
      status: 'new',
      tags: ['vip'],
      estimatedValueCents: 500000,
      createdAt: 1000,
      updatedAt: 1000,
    },
    {
      _id: 'lead-2',
      fullName: 'Wedding Reception',
      company: 'Smith Family',
      status: 'won',
      tags: ['wedding'],
      estimatedValueCents: 800000,
      createdAt: 1000,
      updatedAt: 1000,
    },
  ],
  beos: [
    {
      _id: 'beo-1',
      leadId: 'lead-1',
      leadName: 'Big Corp Gala',
      eventName: 'Holiday Party',
      eventDate: 1726000000000,
      status: 'draft',
      updatedAt: 1000,
    },
  ],
  contracts: [
    {
      _id: 'contract-1',
      leadId: 'lead-2',
      contractNumber: 'CNT-101',
      eventName: 'Smith Wedding',
      status: 'signed',
      updatedAt: 1000,
    },
  ],
  detail: {
    lead: {
      _id: 'lead-1',
      fullName: 'Big Corp Gala',
      company: 'Acme Corp',
      email: 'acme@example.com',
      status: 'new',
      tags: ['vip'],
      estimatedValueCents: 500000,
    },
    notes: [{ _id: 'n1', text: 'Called client', authorName: 'Rep 1', createdAt: 1000 }],
    beos: [],
    contracts: [],
    activityLog: [{ _id: 'a1', kind: 'status_change', detail: 'Moved to new', createdAt: 1000 }],
  },
  forecast: {
    byStage: [{ stage: 'new', probability: 0.2, count: 1, rawValueCents: 500000, weightedValueCents: 100000 }],
    totals: { leadCount: 1, rawValueCents: 500000, weightedValueCents: 100000, wonCount: 1, wonValueCents: 800000 },
  },
  sourceRoi: [
    { source: 'Website', leadCount: 5, wonCount: 2, lostCount: 1, pipelineValueCents: 1000000, wonValueCents: 800000, winRate: 0.4 },
  ],
  staleLeads: {
    thresholdDays: 7,
    leads: [{ id: 'lead-1', fullName: 'Big Corp Gala', status: 'new', email: 'acme@example.com', phone: null, lastActivityAt: null, estimatedValueCents: 500000, daysSinceActivity: 10 }],
  },
  templates: [
    { id: 't1', name: 'Follow-up Email', subject: 'Checking in', body: 'Hi {{name}}, just following up!', variables: ['name'], updatedAt: 1000 },
  ],
  saveLead: vi.fn(),
  saveBeo: vi.fn(),
  saveContract: vi.fn(),
  convertBeoToContract: vi.fn(),
  addNote: vi.fn(),
  emailBeo: vi.fn(),
  saveTemplate: vi.fn(),
  deleteTemplate: vi.fn(),
}));

vi.mock('react-native', () => {
  const R = require('react');
  return {
    Platform: { OS: 'web' },
    Pressable: ({ children, onPress, ...props }: any) =>
      R.createElement('Pressable', { onClick: onPress, ...props }, children),
    ScrollView: ({ children }: any) => R.createElement('ScrollView', null, children),
    View: ({ children, style }: any) => R.createElement('View', { style }, children),
  };
});

vi.mock('react-native-paper', () => {
  const R = require('react');
  const element = (type: string) => ({ children, ...props }: any) =>
    R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return {
    Button: ({ children, onPress, disabled, ...props }: any) =>
      R.createElement('button', { onClick: onPress, disabled, ...props }, children),
    Card,
    Chip: element('Chip'),
    Divider: element('Divider'),
    IconButton: ({ icon, onPress }: any) =>
      R.createElement('button', { onClick: onPress, 'data-icon': icon }, icon),
    SegmentedButtons: ({ value, onValueChange, buttons }: any) =>
      R.createElement(
        'div',
        { 'data-segmented': value },
        buttons.map((b: any) =>
          R.createElement('button', { key: b.value, onClick: () => onValueChange(b.value) }, b.label),
        ),
      ),
    Text: element('Text'),
    TextInput: ({ value, onChangeText, label, placeholder, ...props }: any) =>
      R.createElement('input', {
        value,
        placeholder: label || placeholder,
        onChange: (e: any) => onChangeText(e.target.value),
        ...props,
      }),
  };
});

vi.mock('@expo/vector-icons', () => ({
  MaterialCommunityIcons: ({ name }: any) => `Icon(${name})`,
}));

vi.mock('../../lib/responsive', () => ({
  useIsDesktop: () => true,
}));

vi.mock('../../lib/theme', () => ({
  accents: [
    { bg: '#e0f2fe', fg: '#0369a1' },
    { bg: '#fef3c7', fg: '#b45309' },
    { bg: '#dcfce7', fg: '#15803d' },
    { bg: '#f3e8ff', fg: '#7e22ce' },
    { bg: '#fee2e2', fg: '#b91c1c' },
    { bg: '#ffedd5', fg: '#c2410c' },
  ],
  colors: {
    primary: '#007aff',
    surface: '#fff',
    background: '#f4f4f4',
    charcoal: '#111',
    muted: '#777',
    border: '#eee',
    danger: '#ff3b30',
    warning: '#ff9500',
    success: '#34c759',
  },
  spacing: { xs: 4, sm: 8, md: 16, lg: 24 },
}));

vi.mock('../../components/AppCard', () => {
  const R = require('react');
  return {
    AnimatedTab: ({ children }: any) => R.createElement('div', { 'data-animated-tab': true }, children),
  };
});

vi.mock('../../lib/railway-api', () => ({
  api: {
    crm: {
      listLeads: 'listLeads',
      listBeos: 'listBeos',
      listContracts: 'listContracts',
      getLead: 'getLead',
      getForecast: 'getForecast',
      getSourceRoi: 'getSourceRoi',
      getStaleLeads: 'getStaleLeads',
      getLeadActivity: 'getLeadActivity',
      listTemplates: 'listTemplates',
      saveLead: 'saveLead',
      saveBeo: 'saveBeo',
      saveContract: 'saveContract',
      convertBeoToContract: 'convertBeoToContract',
      addNote: 'addNote',
      emailBeo: 'emailBeo',
      saveTemplate: 'saveTemplate',
      deleteTemplate: 'deleteTemplate',
    },
  },
}));

vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => {
    if (ref === 'listLeads') return { leads: state.leads, totalCount: state.leads.length, page: 1, limit: 50 };
    if (ref === 'listBeos') return state.beos;
    if (ref === 'listContracts') return state.contracts;
    if (ref === 'getLead') return state.detail;
    if (ref === 'getForecast') return state.forecast;
    if (ref === 'getSourceRoi') return state.sourceRoi;
    if (ref === 'getStaleLeads') return state.staleLeads;
    if (ref === 'getLeadActivity') return state.detail.activityLog;
    if (ref === 'listTemplates') return state.templates;
    return undefined;
  },
  useMutation: (ref: string) => {
    if (ref === 'saveLead') return state.saveLead;
    if (ref === 'saveBeo') return state.saveBeo;
    if (ref === 'saveContract') return state.saveContract;
    if (ref === 'convertBeoToContract') return state.convertBeoToContract;
    if (ref === 'addNote') return state.addNote;
    if (ref === 'emailBeo') return state.emailBeo;
    if (ref === 'saveTemplate') return state.saveTemplate;
    if (ref === 'deleteTemplate') return state.deleteTemplate;
    return vi.fn();
  },
}));

function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}

describe('CrmSalesWorkspace', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.saveLead.mockResolvedValue('lead-new');
    state.saveBeo.mockResolvedValue('beo-new');
    state.convertBeoToContract.mockResolvedValue({ alreadyExisted: false });
    state.saveTemplate.mockResolvedValue('tpl-new');
    state.deleteTemplate.mockResolvedValue(true);
  });

  it('renders null when enabled is false or venueId is undefined', async () => {
    const r1 = createRoot();
    await act(async () => {
      r1.render(<CrmSalesWorkspace venueId={'v1' as any} enabled={false} />);
    });
    expect(r1.container.toJSON()?.children).toEqual([]);

    const r2 = createRoot();
    await act(async () => {
      r2.render(<CrmSalesWorkspace venueId={undefined} enabled={true} />);
    });
    expect(r2.container.toJSON()?.children).toEqual([]);
  });

  it('renders dashboard view with stats, priority deals, and recent documents', async () => {
    const r = createRoot();
    await act(async () => {
      r.render(<CrmSalesWorkspace venueId={'v1' as any} enabled={true} />);
    });

    const json = output(r);
    expect(json).toContain('CRM workspace');
    expect(json).toContain('Pipeline');
    expect(json).toContain('Won revenue');
    expect(json).toContain('Big Corp Gala');
    expect(json).toContain('Holiday Party');
  });

  it('toggles lead form and creates new lead', async () => {
    const r = createRoot();
    await act(async () => {
      r.render(<CrmSalesWorkspace venueId={'v1' as any} enabled={true} />);
    });

    // Click "Lead" button to toggle form
    const leadToggleBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Lead'),
    )[0];
    expect(leadToggleBtn).toBeDefined();

    await act(async () => {
      leadToggleBtn.props.onClick();
    });

    expect(output(r)).toContain('Create lead');

    // Fill in lead Name
    const nameInput = r.container.queryAll(
      (n) => n.type === 'input' && n.props.placeholder === 'Name',
    )[0];
    expect(nameInput).toBeDefined();

    await act(async () => {
      nameInput.props.onChange({ target: { value: 'New Test Lead' } });
    });

    // Click "Save lead"
    const saveBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Save lead'),
    )[0];
    expect(saveBtn).toBeDefined();

    await act(async () => {
      await saveBtn.props.onClick();
    });

    expect(state.saveLead).toHaveBeenCalledWith(
      expect.objectContaining({
        venueId: 'v1',
        fullName: 'New Test Lead',
        status: 'new',
      }),
    );
    expect(output(r)).toContain('Lead created.');
  });

  it('switches between pipeline, contacts, events, contracts, insights, and templates views', async () => {
    const r = createRoot();
    await act(async () => {
      r.render(<CrmSalesWorkspace venueId={'v1' as any} enabled={true} />);
    });

    // Switch to Pipeline
    const pipelineBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Pipeline'),
    )[0];
    expect(pipelineBtn).toBeDefined();

    await act(async () => {
      pipelineBtn.props.onClick();
    });
    expect(output(r)).toContain('Big Corp Gala');

    // Switch to Contacts
    const contactsBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Contacts'),
    )[0];
    await act(async () => {
      contactsBtn.props.onClick();
    });
    expect(output(r)).toContain('Big Corp Gala');

    // Switch to Events
    const eventsBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Events'),
    )[0];
    await act(async () => {
      eventsBtn.props.onClick();
    });
    expect(output(r)).toContain('Holiday Party');

    // Switch to Contracts
    const contractsBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Contracts'),
    )[0];
    await act(async () => {
      contractsBtn.props.onClick();
    });
    expect(output(r)).toContain('Smith Wedding');

    // Switch to Insights
    const insightsBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Insights'),
    )[0];
    await act(async () => {
      insightsBtn.props.onClick();
    });
    expect(output(r)).toContain('Lead source ROI');

    // Switch to Templates
    const templatesBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Templates'),
    )[0];
    await act(async () => {
      templatesBtn.props.onClick();
    });
    expect(output(r)).toContain('Follow-up Email');
  });

  it('converts BEO to contract in Events view', async () => {
    const r = createRoot();
    await act(async () => {
      r.render(<CrmSalesWorkspace venueId={'v1' as any} enabled={true} />);
    });

    // Switch to Events
    const eventsBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Events'),
    )[0];
    await act(async () => {
      eventsBtn.props.onClick();
    });

    const convertBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Convert to contract'),
    )[0];
    expect(convertBtn).toBeDefined();

    await act(async () => {
      convertBtn.props.onClick();
    });

    expect(state.convertBeoToContract).toHaveBeenCalledWith({
      venueId: 'v1',
      beoId: 'beo-1',
    });
  });
});
