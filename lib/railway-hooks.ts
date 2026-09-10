import { useCallback } from 'react';
import { useMutation as useReactMutation, useQuery as useReactQuery, useQueryClient } from '@tanstack/react-query';
import { ApiError, apiRequest } from './api-client';
import { useAuthStore } from './auth-store';
import { locationBody } from './clock-body';
import { getLastRegisteredPushToken, setLastRegisteredPushToken } from './push-token-registry';
import type { RailwayFunctionRef } from './railway-api';

type QueryArgs = Record<string, unknown> | 'skip' | undefined;
type Method = 'GET' | 'POST' | 'PATCH' | 'DELETE';

/* eslint-disable @typescript-eslint/no-explicit-any -- route fns are type-erased by design */
type Route = {
  path: string | ((args: any) => string);
  method?: Method;
  body?: (args: any) => any;
  invalidate?: unknown[][];
  timeoutMs?: number;
};

const queryRoutes: Record<string, Route> = {
  'app.getMe': { path: '/v1/app/me' },
  'app.getVenueJoinCode': { path: '/v1/app/venue/join-code' },
  'app.getDashboard': { path: '/v1/app/dashboard' },
  'app.getNotifications': { path: (args) => `/v1/app/notifications${args?.limit ? `?limit=${args.limit}` : ''}` },
  'app.getClockBoard': { path: '/v1/time-clock/board' },
  'app.getMyTimeClock': { path: '/v1/time-clock/me' },
  'app.getMyVenueBilling': { path: '/v1/app/billing' },
  'app.listVenueStaff': { path: '/v1/app/staff' },
  'app.listStaffOnboarding': { path: (args) => `/v1/app/staff/onboarding${args?.profileId ? `?profileId=${encodeURIComponent(args.profileId)}` : ''}` },
  'app.listStaffAuditLog': { path: '/v1/app/staff/audit-log' },
  'app.listStaffRequests': { path: '/v1/staff-requests' },
  'app.getManagerInsights': { path: '/v1/app/manager-insights' },
  'app.exportTimeEntriesCsv': {
    // The selected period travels with the request; without it the export
    // returned recent punches regardless of what the screen showed.
    path: (args) =>
      `/v1/app/time-entries/csv${args?.startDate ? `?startDate=${encodeURIComponent(args.startDate)}&endDate=${encodeURIComponent(args.endDate ?? args.startDate)}` : ''}`,
  },
  'staffAuth.listVenueRoles': { path: '/v1/app/venue-roles' },
  'scheduling.listBlackouts': { path: '/v1/scheduling/blackouts' },
  'scheduling.getManagerSchedule': { path: (args) => `/v1/scheduling/manager${args?.weekStart ? `?weekStart=${encodeURIComponent(args.weekStart)}` : ''}` },
  'scheduling.getLaborForecast': { path: (args) => `/v1/scheduling/labor-forecast${args?.weekStart ? `?weekStart=${encodeURIComponent(args.weekStart)}` : ''}` },
  'scheduling.listScheduleMemory': { path: (args) => `/v1/scheduling/memory${args?.limit ? `?limit=${args.limit}` : ''}` },
  'scheduling.previewAutoSchedule': { path: (args) => `/v1/scheduling/auto-schedule/preview?weekStartDate=${encodeURIComponent(args.weekStartDate ?? '')}` },
  'scheduling.listScheduleTemplates': { path: '/v1/scheduling/templates' },
  'scheduling.getMySchedule': { path: '/v1/scheduling/me' },
  'scheduling.getMyShiftSwaps': { path: '/v1/scheduling/swaps/me' },
  'scheduling.listShiftSwaps': { path: '/v1/scheduling/swaps' },
  'pos.getPosOverview': { path: '/v1/pos/overview' },
  'pos.getSalesSummaryDashboard': { path: (args) => `/v1/pos/sales/summary?windowDays=${args.windowDays ?? 7}${args.startTs ? `&startTs=${args.startTs}` : ''}${args.endTs ? `&endTs=${args.endTs}` : ''}` },
  'pos.getSalesByServer': { path: (args) => `/v1/pos/sales/by-server?windowDays=${args.windowDays ?? 7}${args.startTs ? `&startTs=${args.startTs}` : ''}${args.endTs ? `&endTs=${args.endTs}` : ''}` },
  'pos.getTopMenuItems': { path: (args) => `/v1/pos/sales/top-items?windowDays=${args.windowDays ?? 7}&limit=${args.limit ?? 30}${args.startTs ? `&startTs=${args.startTs}` : ''}${args.endTs ? `&endTs=${args.endTs}` : ''}` },
  'pos.getLaborSummary': { path: (args) => `/v1/pos/labor?windowDays=${args.windowDays ?? 7}${args.startTs ? `&startTs=${args.startTs}` : ''}${args.endTs ? `&endTs=${args.endTs}` : ''}` },
  'operations.getManagerDashboard': { path: '/v1/operations/manager-dashboard' },
  'operations.getDailyBrief': { path: '/v1/operations/daily-brief' },
  'operations.getCommandCenter': { path: '/v1/operations/command-center' },
  'operations.getCommandCenterEvent': { path: (args) => `/v1/operations/command-center/events/${enc(args.eventId ?? args.id)}` },
  'operations.listLogbook': { path: (args) => `/v1/operations/logbook${args?.limit ? `?limit=${args.limit}` : ''}` },
  'operations.getChecklist': {
    path: (args) => `/v1/operations/checklist?kind=${encodeURIComponent(args.kind)}${args?.date ? `&date=${encodeURIComponent(args.date)}` : ''}`,
  },
  'reservations.getReservationsPage': { path: '/v1/reservations' },
  'reservations.exportReservationsCsv': {
    path: (args) =>
      `/v1/reservations/export-csv${args?.startDate ? `?startDate=${encodeURIComponent(args.startDate)}&endDate=${encodeURIComponent(args.endDate ?? args.startDate)}` : ''}`,
  },
  'payroll.getPayrollSummary': { path: (args) => `/v1/payroll/summary${args.startDate ? `?startDate=${args.startDate}&endDate=${args.endDate ?? ''}` : ''}` },
  'payroll.exportPayrollCsv': { path: (args) => `/v1/payroll/export-csv${args.startDate ? `?startDate=${args.startDate}&endDate=${args.endDate ?? ''}` : ''}` },
  'barInventory.getBarStock': { path: '/v1/bar-inventory' },
  'barInventory.getUsageVelocity': { path: '/v1/bar-inventory/velocity' },
  'barInventory.getItemMovements': { path: (args) => `/v1/bar-inventory/${enc(args.itemId)}/movements?limit=${args.limit ?? 50}` },
  'barInventory.exportStockCsv': { path: '/v1/bar-inventory/export-csv' },
  'barInventory.exportMovementsCsv': { path: '/v1/bar-inventory/movements/export-csv' },
  'barInventory.getShrinkageReport': { path: '/v1/bar-inventory/shrinkage' },
  'barInventory.getPurchaseOrder': { path: '/v1/bar-inventory/purchase-order' },
  'barInventory.exportPurchaseOrderCsv': { path: '/v1/bar-inventory/purchase-order/export-csv' },
  'barInventory.getCostHistory': { path: (args) => `/v1/bar-inventory/cost-history/${enc(args.itemId)}` },
  'barInventory.getAgingReport': { path: '/v1/bar-inventory/aging' },
  'barInventory.listPrepBoard': { path: '/v1/bar-inventory/prep-board' },
  'cosmicInsights.getLatestInsights': { path: '/v1/insights' },
  'floor.getActiveFloorPlan': { path: '/v1/floor/active' },
  'floor.getFloorStats': { path: '/v1/floor/stats' },
  'floorBinding.getActiveFloorPlan': { path: '/v1/floor/active' },
  'floorBinding.getUnassignedReservations': { path: (args) => `/v1/floor/unassigned-reservations?withinMinutes=${args.withinMinutes ?? 120}` },
  'floorBinding.getOpenWaitlist': { path: '/v1/floor/waitlist' },
  'chat.listConversations': { path: '/v1/chat/conversations' },
  'chat.listDirectory': { path: '/v1/chat/directory' },
  'chat.getMessages': { path: (args) => `/v1/chat/conversations/${enc(args.conversationId)}/messages` },
  'guests.listGuests': {
    path: (args) =>
      `/v1/guests?page=${args.page ?? 0}&limit=${args.limit ?? 100}${args.search ? `&q=${encodeURIComponent(args.search)}` : ''}`,
  },
  'guests.getGuestProfile': { path: (args) => `/v1/guests/${enc(args.guestId)}` },
  'crm.listLeads': {
    path: (args) =>
      `/v1/crm/leads?page=${args.page ?? 0}&limit=${args.limit ?? 100}${args.search ? `&search=${encodeURIComponent(args.search)}` : ''}`,
  },
  'crm.listBeos': { path: (args) => `/v1/crm/beos?page=${args.page ?? 0}&limit=${args.limit ?? 100}` },
  'crm.listContracts': { path: (args) => `/v1/crm/contracts?page=${args.page ?? 0}&limit=${args.limit ?? 100}` },
  'crm.getLead': { path: (args) => `/v1/crm/leads/${enc(args.leadId)}` },
  'crm.getForecast': { path: '/v1/crm/forecast' },
  'crm.getSourceRoi': { path: '/v1/crm/source-roi' },
  'crm.getStaleLeads': { path: (args) => `/v1/crm/stale-leads${args?.days ? `?days=${args.days}` : ''}` },
  'crm.getLeadActivity': { path: (args) => `/v1/crm/leads/${enc(args.leadId)}/activity` },
  'crm.listTemplates': { path: '/v1/crm/templates' },
  'reservations.getCoverPacing': { path: (args) => `/v1/reservations/cover-pacing?date=${encodeURIComponent(args.date)}` },
  'reservations.guestAutofill': {
    path: (args) =>
      `/v1/reservations/guest-autofill${args?.email ? `?email=${encodeURIComponent(args.email)}` : args?.phone ? `?phone=${encodeURIComponent(args.phone)}` : ''}`,
  },
  'reservations.listHolds': { path: '/v1/reservations/holds' },
  'reservationIntegrations.getReservationIntegrationOverview': { path: '/v1/integrations/reservations' },
  'documents.list': { path: '/v1/documents' },
};

const mutationRoutes: Record<string, Route> = {
  'app.markNotificationRead': {
    path: (args) => `/v1/app/notifications/${enc(args.notificationId ?? args.id ?? args)}/read`,
    method: 'POST',
    invalidate: [['app', 'getNotifications']],
  },
  'app.updateVenue': {
    path: '/v1/app/venue',
    method: 'PATCH',
    body: ({ name, latitude, longitude, geofenceRadiusM, timezone }) => ({ name, latitude, longitude, geofenceRadiusM, timezone }),
    invalidate: [['app', 'getMe'], ['app', 'getDashboard']],
  },
  'app.rotateVenueJoinCode': {
    path: '/v1/app/venue/join-code/rotate',
    method: 'POST',
    body: () => ({}),
    invalidate: [['app', 'getVenueJoinCode']],
  },
  'app.switchVenue': {
    path: '/v1/app/switch-venue',
    method: 'POST',
    body: ({ venueId }) => ({ venueId }),
    invalidate: [['app', 'getMe'], ['app', 'getDashboard']],
  },
  'app.registerVenue': {
    path: '/v1/app/register-venue',
    method: 'POST',
    body: ({ businessName, ownerName, phone, address, venueType, staffRange, latitude, longitude, timezone }) => ({ businessName, ownerName, phone, address, venueType, staffRange, latitude, longitude, timezone }),
    invalidate: [['app', 'getMe'], ['app', 'getDashboard']],
  },
  'app.deleteMyAccount': {
    path: '/v1/app/me',
    method: 'DELETE',
    body: ({ deleteOwnedVenues }) => ({ deleteOwnedVenues: Boolean(deleteOwnedVenues) }),
  },
  'app.clockIn': { path: '/v1/time-clock/clock-in', method: 'POST', body: locationBody, invalidate: clockInvalidations() },
  'app.clockOut': { path: '/v1/time-clock/clock-out', method: 'POST', body: locationBody, invalidate: clockInvalidations() },
  'app.breakStart': { path: '/v1/time-clock/break-start', method: 'POST', body: (args) => ({ type: args.type }), invalidate: clockInvalidations() },
  'app.breakEnd': { path: '/v1/time-clock/break-end', method: 'POST', body: () => ({}), invalidate: clockInvalidations() },
  'app.upsertVenueStaff': {
    path: '/v1/app/staff',
    method: 'POST',
    body: ({ venueId, staffId, email, fullName, role, jobTitle, phone, altPhone, address, dateOfBirth, certifications }) => ({ venueId, staffId, email, fullName, role, jobTitle, phone, altPhone, address, dateOfBirth, certifications }),
    invalidate: [['app', 'listVenueStaff'], ['app', 'listStaffOnboarding'], ['app', 'listStaffAuditLog'], ['app', 'getDashboard']],
  },
  'app.deactivateVenueStaff': {
    path: (args) => `/v1/app/staff/${enc(args.staffId ?? args.id ?? args)}`,
    method: 'DELETE',
    invalidate: [['app', 'listVenueStaff'], ['app', 'listStaffAuditLog'], ['app', 'getDashboard']],
  },
  'app.updateStaffOnboardingTask': {
    path: (args) => `/v1/app/staff/onboarding/${enc(args.taskId ?? args.id)}`,
    method: 'PATCH',
    body: ({ status }) => ({ status }),
    invalidate: [['app', 'listStaffOnboarding'], ['app', 'listStaffAuditLog']],
  },
  'staffAuth.addVenueRole': {
    path: '/v1/app/venue-roles',
    method: 'POST',
    body: ({ name }) => ({ name }),
    invalidate: [['staffAuth', 'listVenueRoles']],
  },
  'staffAuth.removeVenueRole': {
    path: (args) => `/v1/app/venue-roles/${enc(args.roleId ?? args.id ?? args)}`,
    method: 'DELETE',
    invalidate: [['staffAuth', 'listVenueRoles']],
  },
  'invites.createInvite': {
    path: '/v1/app/invites',
    method: 'POST',
    body: ({ role, jobTitle }) => ({ role, jobTitle }),
  },
  'app.parseStaffImport': {
    path: '/v1/app/staff/import/parse',
    method: 'POST',
    body: ({ text }) => ({ text }),
  },
  'app.commitStaffImport': {
    path: '/v1/app/staff/import/commit',
    method: 'POST',
    body: ({ venueId, items }) => ({ venueId, items }),
    invalidate: [['app', 'listVenueStaff'], ['app', 'listStaffOnboarding'], ['app', 'listStaffAuditLog'], ['app', 'getDashboard']],
  },
  'scheduling.previewAiSchedule': {
    path: (args) => `/v1/scheduling/ai-schedule/preview?weekStartDate=${encodeURIComponent(args?.weekStartDate ?? '')}`,
    method: 'GET',
  },
  'scheduling.commitAiSchedule': {
    path: '/v1/scheduling/ai-schedule/commit',
    method: 'POST',
    // Strip the preview-only display fields (dayLabel, startTime, endTime,
    // reason, memberName) — the API's ValidationPipe rejects unknown properties.
    body: ({ shifts, weekStartDate }) => ({
      weekStartDate,
      shifts: (shifts ?? []).map((s: any) => ({
        dayIndex: s.dayIndex,
        startMinutes: s.startMinutes,
        endMinutes: s.endMinutes,
        jobTitle: s.jobTitle,
        station: s.station,
        ...(s.profileId ? { profileId: s.profileId } : {}),
      })),
    }),
    invalidate: [['scheduling', 'getManagerSchedule'], ['scheduling', 'getLaborForecast']],
  },
  'operations.addLogbookEntry': {
    path: '/v1/operations/logbook',
    method: 'POST',
    body: ({ category, body, pinned }) => ({ category, body, pinned }),
    invalidate: [['operations', 'listLogbook']],
  },
  'operations.deleteLogbookEntry': {
    path: (args) => `/v1/operations/logbook/${enc(args.id ?? args)}`,
    method: 'DELETE',
    invalidate: [['operations', 'listLogbook']],
  },
  'operations.addChecklistItem': {
    path: '/v1/operations/checklist/items',
    method: 'POST',
    body: ({ kind, title, requiresPhoto }) => ({ kind, title, requiresPhoto }),
    invalidate: [['operations', 'getChecklist'], ...readinessInvalidations()],
  },
  'operations.removeChecklistItem': {
    path: (args) => `/v1/operations/checklist/items/${enc(args.id ?? args)}`,
    method: 'DELETE',
    invalidate: [['operations', 'getChecklist'], ...readinessInvalidations()],
  },
  'operations.completeChecklistItem': {
    path: (args) => `/v1/operations/checklist/complete/${enc(args.completionId)}`,
    method: 'POST',
    body: ({ photoBase64, photoMimeType }) => ({ photoBase64, photoMimeType }),
    invalidate: [['operations', 'getChecklist'], ...readinessInvalidations()],
  },
  'operations.generateExecutionWorkspace': {
    path: (args) => `/v1/operations/command-center/events/${enc(args.eventId ?? args.id)}/generate`,
    method: 'POST',
    body: () => ({}),
    invalidate: [['operations', 'getCommandCenterEvent'], ...readinessInvalidations()],
  },
  'operations.updateExecutionTask': {
    path: (args) => `/v1/operations/command-center/tasks/${enc(args.taskId ?? args.id)}`,
    method: 'PATCH',
    body: ({ status }) => ({ status }),
    invalidate: [['operations', 'getCommandCenterEvent'], ['barInventory', 'listPrepBoard'], ...readinessInvalidations()],
  },
  'operations.updateExecutionTimeline': {
    path: (args) => `/v1/operations/command-center/timeline/${enc(args.itemId ?? args.id)}`,
    method: 'PATCH',
    body: ({ status }) => ({ status }),
    invalidate: [['operations', 'getCommandCenterEvent'], ...readinessInvalidations()],
  },
  'operations.updateExecutionVendor': {
    path: (args) => `/v1/operations/command-center/vendors/${enc(args.vendorId ?? args.id)}`,
    method: 'PATCH',
    body: ({ status }) => ({ status }),
    invalidate: [['operations', 'getCommandCenterEvent'], ...readinessInvalidations()],
  },
  'operations.createExecutionIncident': {
    path: (args) => `/v1/operations/command-center/events/${enc(args.eventId)}/incidents`,
    method: 'POST',
    body: ({ title, severity, blocksReadiness }) => ({ title, severity, blocksReadiness }),
    invalidate: [['operations', 'getCommandCenterEvent'], ...readinessInvalidations()],
  },
  'operations.resolveExecutionIncident': {
    path: (args) => `/v1/operations/command-center/incidents/${enc(args.incidentId ?? args.id)}`,
    method: 'PATCH',
    body: ({ status }) => ({ status }),
    invalidate: [['operations', 'getCommandCenterEvent'], ...readinessInvalidations()],
  },
  'app.createStaffRequest': {
    path: '/v1/staff-requests',
    method: 'POST',
    body: stripVenue,
    invalidate: [['app', 'listStaffRequests']],
  },
  'app.reviewStaffRequest': {
    path: (args) => `/v1/staff-requests/${enc(args.requestId ?? args.id)}`,
    method: 'PATCH',
    body: ({ status, responseNotes }) => ({ status, responseNotes }),
    invalidate: [['app', 'listStaffRequests']],
  },
  'scheduling.addBlackout': {
    path: '/v1/scheduling/blackouts',
    method: 'POST',
    body: stripVenue,
    invalidate: [['scheduling', 'listBlackouts']],
  },
  'scheduling.removeBlackout': {
    path: (args) => `/v1/scheduling/blackouts/${enc(args.blackoutId ?? args.id ?? args)}`,
    method: 'DELETE',
    invalidate: [['scheduling', 'listBlackouts']],
  },
  'scheduling.createShift': {
    path: '/v1/scheduling/shifts',
    method: 'POST',
    body: stripVenue,
    invalidate: scheduleInvalidations(),
  },
  'scheduling.updateShift': {
    path: (args) => `/v1/scheduling/shifts/${enc(args.shiftId ?? args.id)}`,
    method: 'PATCH',
    body: stripVenueAndIds,
    invalidate: scheduleInvalidations(),
  },
  'scheduling.assignShift': {
    path: (args) => `/v1/scheduling/shifts/${enc(args.shiftId ?? args.id)}/assign`,
    method: 'PATCH',
    body: ({ profileId }) => ({ profileId }),
    invalidate: scheduleInvalidations(),
  },
  'scheduling.unassignShift': {
    path: (args) => `/v1/scheduling/shifts/${enc(args.shiftId ?? args.id)}/assign`,
    method: 'PATCH',
    body: () => ({ profileId: undefined }),
    invalidate: scheduleInvalidations(),
  },
  'scheduling.deleteShift': {
    path: (args) => `/v1/scheduling/shifts/${enc(args.shiftId ?? args.id ?? args)}`,
    method: 'DELETE',
    invalidate: scheduleInvalidations(),
  },
  'scheduling.publishSchedule': { path: '/v1/scheduling/publish', method: 'POST', body: ({ weekStart }) => ({ weekStart }), invalidate: scheduleInvalidations() },
  'scheduling.setLaborBudget': {
    path: '/v1/scheduling/labor-budget',
    method: 'PATCH',
    body: ({ weeklyLaborBudgetHours }) => ({ weeklyLaborBudgetHours }),
    invalidate: scheduleInvalidations(),
  },
  'scheduling.saveScheduleTemplate': {
    path: '/v1/scheduling/templates',
    method: 'POST',
    body: ({ name, weekStart }) => ({ name, weekStart }),
    invalidate: [['scheduling', 'listScheduleTemplates']],
  },
  'scheduling.applyScheduleTemplate': {
    path: (args) => `/v1/scheduling/templates/${enc(args.templateId ?? args.id)}/apply`,
    method: 'POST',
    body: ({ replace, weekStart }) => ({ replace, weekStart }),
    invalidate: scheduleInvalidations(),
  },
  'scheduling.deleteScheduleTemplate': {
    path: (args) => `/v1/scheduling/templates/${enc(args.templateId ?? args.id ?? args)}`,
    method: 'DELETE',
    invalidate: [['scheduling', 'listScheduleTemplates']],
  },
  'scheduling.copyDayShifts': { path: '/v1/scheduling/copy-day', method: 'POST', body: stripVenue, invalidate: scheduleInvalidations() },
  'scheduling.clearWeek': { path: '/v1/scheduling/clear-week', method: 'POST', body: ({ weekStart }) => ({ weekStart }), invalidate: scheduleInvalidations() },
  'scheduling.restoreShifts': { path: '/v1/scheduling/restore-shifts', method: 'POST', body: ({ shifts, weekStart }) => ({ shifts, weekStart }), invalidate: scheduleInvalidations() },
  'scheduling.addScheduleMemoryNote': {
    path: '/v1/scheduling/memory',
    method: 'POST',
    body: ({ title, detail, weekStart }) => ({ title, detail, weekStart }),
    invalidate: [['scheduling', 'listScheduleMemory']],
  },
  'scheduling.applyAutoSchedule': {
    path: '/v1/scheduling/auto-schedule/apply',
    method: 'POST',
    body: ({ assignments, weekStartDate }) => ({ assignments, weekStartDate }),
    invalidate: scheduleInvalidations(),
  },
  'scheduling.claimOpenShift': {
    path: (args) => `/v1/scheduling/shifts/${enc(args.shiftId ?? args.id)}/claim`,
    method: 'POST',
    body: () => ({}),
    invalidate: scheduleInvalidations(),
  },
  'scheduling.requestDropShift': {
    path: '/v1/staff-requests',
    method: 'POST',
    body: ({ shiftId }) => ({
      kind: 'drop_shift',
      title: 'Drop shift request',
      details: 'Requesting manager approval to drop this assigned shift.',
      requestedShiftId: shiftId,
    }),
    invalidate: [['app', 'listStaffRequests'], ...scheduleInvalidations()],
  },
  'scheduling.proposeShiftSwap': { path: '/v1/scheduling/swaps', method: 'POST', body: stripVenue, invalidate: scheduleInvalidations() },
  'scheduling.respondToShiftSwap': {
    path: (args) => `/v1/scheduling/swaps/${enc(args.swapId ?? args.id)}/respond`,
    method: 'PATCH',
    body: ({ accept }) => ({ accept }),
    invalidate: scheduleInvalidations(),
  },
  'scheduling.reviewShiftSwap': {
    path: (args) => `/v1/scheduling/swaps/${enc(args.swapId ?? args.id)}/review`,
    method: 'PATCH',
    body: ({ approve }) => ({ approve }),
    invalidate: scheduleInvalidations(),
  },
  'pos.upsertPosConnection': { path: '/v1/pos/connections', method: 'POST', body: ({ provider, externalLocationId, status }) => ({ provider, externalLocationId, status }), invalidate: [['pos', 'getPosOverview']] },
  'pos.rotatePosConnectionSecret': { path: (args) => `/v1/pos/connections/${enc(args.connectionId ?? args.id)}/rotate-secret`, method: 'POST', body: () => ({}), invalidate: [['pos', 'getPosOverview']] },
  'reservationIntegrations.upsertReservationConnection': { path: '/v1/integrations/reservations', method: 'POST', body: stripVenue },
  'guests.rotateLeadsWebhookSecret': { path: '/v1/guests/rotate-webhook-secret', method: 'POST', body: () => ({}), invalidate: [['guests', 'listGuests']] },
  'operations.upsertManagerGoal': { path: '/v1/operations/manager-goal', method: 'PATCH', body: stripVenue, invalidate: [['operations', 'getManagerDashboard']] },
  'barInventory.upsertBarItem': { path: '/v1/bar-inventory', method: 'POST', body: stripVenue, invalidate: inventoryInvalidations() },
  'barInventory.recordBarStockMovement': { path: (args) => `/v1/bar-inventory/${enc(args.itemId)}/movement`, method: 'POST', body: ({ movementType, quantity, notes, operationId }) => ({ movementType, quantity, notes, operationId }), invalidate: inventoryInvalidations() },
  'barInventory.importParsedBarItems': { path: '/v1/bar-inventory/import', method: 'POST', body: ({ items }) => ({ items }), invalidate: inventoryInvalidations() },
  'barInventory.parseBarInventoryInput': { path: '/v1/bar-inventory/parse', method: 'POST', body: ({ text, imageBase64, imageMimeType }) => ({ text, imageBase64, imageMimeType }) },
  'barInventory.updateItemCost': { path: (args) => `/v1/bar-inventory/${enc(args.itemId)}/cost`, method: 'PATCH', body: ({ unitCostCents }) => ({ unitCostCents }), invalidate: inventoryInvalidations() },
  'barInventory.lookupBySku': { path: (args) => `/v1/bar-inventory/sku/${encodeURIComponent(args.sku)}`, method: 'GET' },
  'barInventory.sendPurchaseOrderEmail': { path: '/v1/bar-inventory/purchase-order/send-email', method: 'POST', body: () => ({}) },
  'barInventory.sendInventoryDigest': { path: '/v1/bar-inventory/send-digest', method: 'POST', body: () => ({}) },
  'barInventory.upsertPrepBoardItem': {
    path: '/v1/bar-inventory/prep-board',
    method: 'POST',
    body: ({ itemId, kind, title, quantity, unit, station, notes, dueDate, status }) => ({ itemId, kind, title, quantity, unit, station, notes, dueDate, status }),
    invalidate: [['barInventory', 'listPrepBoard'], ...readinessInvalidations()],
  },
  'barInventory.updatePrepBoardItemStatus': {
    path: (args) => `/v1/bar-inventory/prep-board/${enc(args.itemId ?? args.id)}/status`,
    method: 'PATCH',
    body: ({ status }) => ({ status }),
    invalidate: [['barInventory', 'listPrepBoard'], ...readinessInvalidations()],
  },
  'chat.ensureChatSetup': { path: '/v1/chat/setup', method: 'POST', body: () => ({}), invalidate: [['chat', 'listConversations']] },
  'chat.openDm': { path: '/v1/chat/dm', method: 'POST', body: ({ targetProfileId }) => ({ targetProfileId }), invalidate: [['chat', 'listConversations']] },
  'chat.createGroup': { path: '/v1/chat/group', method: 'POST', body: ({ name, memberIds }) => ({ name, memberIds }), invalidate: [['chat', 'listConversations']] },
  'chat.deleteConversation': { path: (args) => `/v1/chat/conversations/${enc(args.conversationId ?? args.id ?? args)}`, method: 'DELETE', invalidate: [['chat', 'listConversations']] },
  'chat.sendMessage': { path: (args) => `/v1/chat/conversations/${enc(args.conversationId)}/messages`, method: 'POST', body: (args) => ({ text: args.text, shiftId: args.shiftId, swapId: args.swapId, imageUrl: args.imageUrl }), invalidate: [['chat', 'getMessages']] },
  'chat.toggleReaction': { path: (args) => `/v1/chat/messages/${enc(args.messageId)}/react`, method: 'POST', body: ({ emoji }) => ({ emoji }), invalidate: [['chat', 'getMessages']] },
  'chat.editMessage': { path: (args) => `/v1/chat/messages/${enc(args.messageId)}`, method: 'PATCH', body: ({ text }) => ({ text }), invalidate: [['chat', 'getMessages']] },
  'chat.uploadImage': { path: '/v1/chat/images', method: 'POST', body: ({ dataBase64, mimeType }) => ({ dataBase64, mimeType }) },
  'floor.saveFloorPlan': { path: '/v1/floor', method: 'POST', body: mapFloorPlanBody, invalidate: floorInvalidations() },
  'floor.clearActiveFloorPlan': { path: '/v1/floor', method: 'DELETE', invalidate: floorInvalidations() },
  'tables.markDirty': { path: (args) => `/v1/floor/tables/${enc(args.tableId ?? args.id ?? args)}/status`, method: 'PATCH', body: () => ({ status: 'dirty' }), invalidate: floorInvalidations() },
  'tables.markClean': { path: (args) => `/v1/floor/tables/${enc(args.tableId ?? args.id ?? args)}/status`, method: 'PATCH', body: () => ({ status: 'available' }), invalidate: floorInvalidations() },
  'tables.mergeTablesForParty': { path: '/v1/floor/tables/merge', method: 'POST', body: stripVenue, invalidate: floorActiveInvalidations() },
  'tables.splitMergedTables': { path: (args) => `/v1/floor/tables/merge-groups/${enc(args.mergeGroupId ?? args.id ?? args)}/split`, method: 'POST', body: () => ({}), invalidate: floorActiveInvalidations() },
  'floorBinding.releaseAssignment': { path: (args) => `/v1/floor/assignments/${enc(args.assignmentId ?? args.tableId ?? args.id ?? args)}`, method: 'DELETE', invalidate: floorInvalidations() },
  'floorBinding.assignReservationToTables': { path: '/v1/floor/assign-reservation', method: 'POST', body: ({ reservationId, tableIds, holdType, startsAt, endsAt }) => ({ reservationId, tableIds, holdType, startsAt, endsAt }), invalidate: floorInvalidations() },
  'floorBinding.addToWaitlist': { path: '/v1/floor/waitlist', method: 'POST', body: ({ guestName, partySize, phone, guestPhone, email, notes }) => ({ guestName, partySize, phone: phone ?? guestPhone, email, notes }), invalidate: floorWaitlistInvalidations() },
  'floorBinding.markWaitlistReady': { path: (args) => `/v1/floor/waitlist/${enc(args.waitlistId ?? args.id ?? args)}/ready`, method: 'PATCH', body: () => ({}), invalidate: floorWaitlistInvalidations() },
  'floorBinding.removeFromWaitlist': { path: (args) => `/v1/floor/waitlist/${enc(args.waitlistId ?? args.id ?? args)}`, method: 'DELETE', invalidate: floorWaitlistInvalidations() },
  'floorBinding.assignWaitlistToTables': {
    path: '/v1/floor/assign-waitlist',
    method: 'POST',
    body: ({ waitlistId, tableIds, holdType, startsAt, endsAt }) => ({ waitlistId, tableIds, holdType, startsAt, endsAt }),
    invalidate: floorInvalidations(),
  },
  'guests.upsertGuest': { path: '/v1/guests', method: 'POST', body: stripVenue, invalidate: [['guests', 'listGuests']] },
  'guests.ingestLeads': { path: '/v1/guests/ingest-leads', method: 'POST', body: ({ leads }) => ({ leads }), invalidate: [['guests', 'listGuests']] },
  'guests.removeGuest': { path: (args) => `/v1/guests/${enc(args.guestId ?? args.id ?? args)}`, method: 'DELETE', invalidate: [['guests', 'listGuests']] },
  'crm.saveLead': { path: '/v1/crm/leads', method: 'POST', body: stripVenue, invalidate: [['crm', 'listLeads']] },
  'crm.saveBeo': { path: '/v1/crm/beos', method: 'POST', body: stripVenue, invalidate: [['crm', 'listBeos']] },
  'crm.saveContract': { path: '/v1/crm/contracts', method: 'POST', body: stripVenue, invalidate: [['crm', 'listContracts']] },
  'crm.convertBeoToContract': { path: (args) => `/v1/crm/beos/${enc(args.beoId ?? args.id)}/convert`, method: 'POST', body: () => ({}), invalidate: [['crm', 'listBeos'], ['crm', 'listContracts']] },
  'crm.addNote': { path: (args) => `/v1/crm/leads/${enc(args.leadId)}/notes`, method: 'POST', body: ({ text }) => ({ text }), invalidate: [['crm', 'listLeads'], ['crm', 'getLeadActivity']] },
  'crm.emailBeo': {
    path: (args) => `/v1/crm/beos/${enc(args.beoId)}/email`,
    method: 'POST',
    body: ({ toEmail, message }) => ({ toEmail, message }),
    invalidate: [['crm', 'listBeos']],
  },
  'crm.saveTemplate': {
    path: '/v1/crm/templates',
    method: 'POST',
    body: stripVenue,
    invalidate: [['crm', 'listTemplates']],
  },
  'crm.deleteTemplate': {
    path: (args) => `/v1/crm/templates/${enc(args.templateId)}`,
    method: 'DELETE',
    body: () => ({}),
    invalidate: [['crm', 'listTemplates']],
  },
  'crm.renderTemplate': {
    path: (args) => `/v1/crm/templates/${enc(args.templateId)}/render`,
    method: 'POST',
    body: ({ leadId, beoId }) => ({ leadId, beoId }),
  },
  'reservations.saveReservation': { path: '/v1/reservations', method: 'POST', body: mapReservationBody, invalidate: [['reservations', 'getReservationsPage']] },
  'reservations.removeReservation': { path: (args) => `/v1/reservations/${enc(args.reservationId ?? args.id ?? args)}`, method: 'DELETE', invalidate: [['reservations', 'getReservationsPage']] },
  'reservations.createHold': {
    path: '/v1/reservations/holds',
    method: 'POST',
    body: ({ startsAt, endsAt, reason }) => ({ startsAt, endsAt, reason }),
    invalidate: [['reservations', 'listHolds']],
  },
  'reservations.deleteHold': {
    path: (args) => `/v1/reservations/holds/${enc(args.holdId)}`,
    method: 'DELETE',
    invalidate: [['reservations', 'listHolds']],
  },
  'payroll.recordPayrollExport': { path: '/v1/payroll/record-export', method: 'POST', body: stripVenue },
  'push.registerPushToken': {
    path: '/v1/push/token',
    method: 'POST',
    body: ({ token, platform }) => ({ token, platform }),
  },
  'documents.upload': {
    path: '/v1/documents',
    method: 'POST',
    body: ({ title, fileName, mimeType, category, dataBase64 }) => ({ title, fileName, mimeType, category, dataBase64 }),
    invalidate: [['documents', 'list']],
    timeoutMs: 120_000,
  },
  'documents.access': {
    path: (args) => `/v1/documents/${enc(args.documentId ?? args.id)}/access`,
    method: 'POST',
    body: () => ({}),
  },
  'documents.remove': {
    path: (args) => `/v1/documents/${enc(args.documentId ?? args.id)}`,
    method: 'DELETE',
    invalidate: [['documents', 'list']],
  },
};

/** Exposed only for the contract-parity test and developer diagnostics. */
export function useQuery<T = any>(ref: RailwayFunctionRef, args?: QueryArgs): T | undefined {
  const key = getKey(ref);
  const route = queryRoutes[key];
  if (!route) throw new Error(`Unknown Railway query route: ${key}`);
  const authEpoch = useAuthStore((state) => state.authEpoch);
  const userId = useAuthStore((state) => state.user?.id ?? null);
  const venueId = useAuthStore((state) => state.venue?.id ?? null);
  const token = useAuthStore((state) => state.token);
  // Never fire authenticated API queries without a session token — route
  // protection must not depend on every screen remembering to gate its query.
  const enabled = args !== 'skip' && Boolean(token);
  const query = useReactQuery({
    queryKey: [...key.split('.'), args, authEpoch, userId, venueId],
    enabled,
    queryFn: ({ signal }) => requestRoute<T>(route, args, signal),
    // Legacy data-only callers cannot represent an error state. Throw into the
    // nearest recoverable screen/root boundary instead of returning undefined
    // forever and rendering an endless loading skeleton.
    //
    // Scoped to first load only. `throwOnError: true` also fires when a
    // BACKGROUND refetch fails on a query that already holds good data, which
    // replaced a perfectly usable screen with the crash boundary on any
    // transient network blip — and for the getMe call in app/(tabs)/_layout.tsx,
    // that boundary is the root one, so the whole app went down.
    throwOnError: (error, query) => query.state.data === undefined && !(error instanceof ApiError && error.status === 402),
  });
  // Only a pending/disabled query leaves data undefined. Errors are handled by
  // ErrorBoundary; new screens should still prefer useQueryState for inline UX.
  return query.data;
}

export function useQueryState<T = any>(ref: RailwayFunctionRef, args?: QueryArgs) {
  const key = getKey(ref);
  const route = queryRoutes[key];
  if (!route) throw new Error(`Unknown Railway query route: ${key}`);
  const authEpoch = useAuthStore((state) => state.authEpoch);
  const userId = useAuthStore((state) => state.user?.id ?? null);
  const venueId = useAuthStore((state) => state.venue?.id ?? null);
  const token = useAuthStore((state) => state.token);
  const enabled = args !== 'skip' && Boolean(token);
  const query = useReactQuery({
    queryKey: [...key.split('.'), args, authEpoch, userId, venueId],
    enabled,
    queryFn: ({ signal }) => requestRoute<T>(route, args, signal),
  });
  // A 402 is not a failure to show as an error — it means the venue's plan does
  // not cover this route (see SubscriptionGuard). Screens that render a
  // paid-only panel need to tell it apart from "still loading", otherwise the
  // panel sits on a skeleton for the whole trial.
  const subscriptionRequired = query.error instanceof ApiError && query.error.status === 402;
  return {
    data: query.data,
    error: subscriptionRequired ? null : query.error,
    subscriptionRequired,
    isLoading: enabled && query.isLoading,
    refetch: query.refetch,
  };
}

export function useMutation<TArgs = any, TResult = any>(
  ref: RailwayFunctionRef,
): (args: TArgs) => Promise<TResult> {
  const key = getKey(ref);
  const route = mutationRoutes[key];
  const queryClient = useQueryClient();
  const mutation = useReactMutation({
    mutationFn: async (args: TArgs) => {
      if (!route) {
        throw new Error('This feature is still being moved to the Railway API.');
      }
      return requestRoute<TResult>(route, args);
    },
    onSuccess: async () => {
      const invalidations = route?.invalidate ?? [key.split('.')];
      await Promise.all(invalidations.map((queryKey) => queryClient.invalidateQueries({ queryKey })));
    },
  });
  const mutateAsync = mutation.mutateAsync;
  return useCallback((args: TArgs) => mutateAsync(args), [mutateAsync]);
}

export function useAction<TArgs = any, TResult = any>(
  ref: RailwayFunctionRef,
): (args: TArgs) => Promise<TResult> {
  return useMutation<TArgs, TResult>(ref);
}

export function useAuthActions() {
  return {
    signIn: async () => {
      throw new Error('Use Railway password auth instead.');
    },
    // Pass this device's push token so the server unregisters only it, not
    // every device the account has ever signed into.
    signOut: async () => {
      const result = await apiRequest<{ ok: true }>('/v1/auth/logout', {
        method: 'POST',
        body: { pushToken: getLastRegisteredPushToken() ?? undefined },
      });
      setLastRegisteredPushToken(null);
      return result;
    },
  };
}

function getKey(ref: RailwayFunctionRef) {
  return ref.__railwayKey;
}

function requestRoute<T>(route: Route, args: any, signal?: AbortSignal): Promise<T> {
  const path = typeof route.path === 'function' ? route.path(args ?? {}) : route.path;
  return apiRequest<T>(path, {
    expectedProfileId: args?.ownerId,
    expectedVenueId: args?.ownerId ? args?.venueId : undefined,
    method: route.method ?? 'GET',
    signal,
    timeoutMs: route.timeoutMs,
    body: route.method && route.method !== 'GET'
      ? route.body?.(args ?? {}) ?? (route.method === 'DELETE' ? undefined : args ?? {})
      : undefined,
  });
}

function stripVenue(args: any) {
  const { venueId, ...rest } = args ?? {};
  return rest;
}

function stripVenueAndIds(args: any) {
  const { venueId, shiftId, id, ...rest } = args ?? {};
  return rest;
}

function enc(value: unknown): string {
  return encodeURIComponent(String(value ?? ''));
}

function clockInvalidations() {
  return [['app', 'getClockBoard'], ['app', 'getDashboard'], ['app', 'getMyTimeClock']];
}

function floorActiveInvalidations() {
  return [['floor', 'getActiveFloorPlan'], ['floorBinding', 'getActiveFloorPlan']];
}

function floorWaitlistInvalidations() {
  return [['floorBinding', 'getOpenWaitlist']];
}

function floorInvalidations() {
  return [...floorActiveInvalidations(), ...floorWaitlistInvalidations(), ['floor', 'getFloorStats']];
}

function inventoryInvalidations() {
  // Every derived inventory view, not just the stock list. A movement or a cost
  // change feeds the reorder list, velocity, shrinkage and aging reports too;
  // invalidating only getBarStock left an already-open purchase order telling
  // the manager to reorder an item that had just been counted back to par.
  return [
    ['barInventory', 'getBarStock'],
    ['barInventory', 'getPurchaseOrder'],
    ['barInventory', 'getUsageVelocity'],
    ['barInventory', 'getShrinkageReport'],
    ['barInventory', 'getAgingReport'],
    ['barInventory', 'getItemMovements'],
    ['barInventory', 'getCostHistory'],
  ];
}

/**
 * Home's readiness score is computed from the checklist, staffing and event
 * work. A mutation that moves any of those has to invalidate the Home queries
 * as well, or Home keeps reporting a venue ready while the screen the manager
 * just used says otherwise.
 */
function readinessInvalidations() {
  return [['app', 'getDashboard'], ['operations', 'getCommandCenter'], ['operations', 'getManagerDashboard'], ['operations', 'getDailyBrief']];
}

function scheduleInvalidations() {
  return [
    ['scheduling', 'getManagerSchedule'],
    ['scheduling', 'getLaborForecast'],
    ['scheduling', 'getMySchedule'],
    ['scheduling', 'getMyShiftSwaps'],
    ['scheduling', 'listShiftSwaps'],
    ...readinessInvalidations(),
  ];
}

function normalizeReservationTimeInput(value: unknown) {
  if (typeof value === 'number') return new Date(value).toISOString();
  if (value instanceof Date) return value.toISOString();
  return value;
}

function mapReservationBody(args: any) {
  const { venueId, guestPhone, guestEmail, phone, email, reservationTime, ...rest } = args ?? {};
  return {
    ...rest,
    reservationTime: normalizeReservationTimeInput(reservationTime),
    phone: phone ?? guestPhone,
    email: email ?? guestEmail,
  };
}

function mapFloorPlanBody(args: any) {
  const { venueId, tables, chairs, name, width, height, backgroundImageUrl } = args ?? {};
  return {
    ...(name ? { name } : {}),
    ...(typeof width === 'number' ? { width } : {}),
    ...(typeof height === 'number' ? { height } : {}),
    ...(typeof backgroundImageUrl === 'string' ? { backgroundImageUrl } : {}),
    tables: (tables ?? []).map((table: any) => ({
      id: table.id,
      label: table.label,
      x: table.x,
      y: table.y,
      width: table.width,
      height: table.height,
      shape: table.shape,
      section: table.section,
      capacity: table.capacity ?? table.seats,
      seatLabelStyle: table.seatLabelStyle,
      rotation: table.rotation,
      minSpend: table.minSpend,
      isReservable: table.isReservable,
    })),
    chairs: (chairs ?? []).map((chair: any) => ({
      x: chair.x,
      y: chair.y,
      rotation: chair.rotation,
      ...(chair.label ? { label: chair.label } : {}),
    })),
  };
}
