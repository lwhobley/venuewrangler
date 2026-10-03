import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/crm_beo.dart';
import '../domain/crm_contract.dart';
import '../domain/crm_lead.dart';

abstract class CrmRepository {
  Future<List<CrmLead>> getLeads({required String venueId, String? search, int limit = 100});
  Future<CrmLead> createLead({
    required String venueId,
    required String fullName,
    String? email,
    String? phone,
    String? company,
    String? source,
    int? estimatedValueCents,
  });
  Future<void> updateLeadStatus({required String leadId, required String status});

  Future<List<CrmNote>> getNotes({required String leadId});
  Future<void> addNote({required String leadId, required String text});

  Future<List<CrmActivityLogEntry>> getActivity({required String leadId, int limit = 50});

  Future<List<CrmBeo>> getBeos({required String venueId, int limit = 100});
  Future<CrmBeo> createBeo({
    required String venueId,
    String? leadId,
    required String eventName,
    DateTime? eventDate,
    int? guestCount,
    String? venueSpace,
    int? depositCents,
  });
  Future<void> updateBeoStatus({required String beoId, required String status});
  Future<bool> waiveBeoDeposit({required String beoId});
  Future<({String contractId, bool alreadyExisted})> convertBeoToContract({required String beoId});

  Future<List<CrmContract>> getContracts({required String venueId, int limit = 100});
  Future<void> updateContractStatus({required String contractId, required String status});

  Future<List<CrmForecastRow>> getForecast({required String venueId});
  Future<List<CrmStaleLead>> getStaleLeads({required String venueId, int days = 5});
}

class SupabaseCrmRepository implements CrmRepository {
  SupabaseCrmRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<CrmLead>> getLeads({required String venueId, String? search, int limit = 100}) async {
    var query = _client.from('crm_leads').select().eq('venue_id', venueId).isFilter('deleted_at', null);

    if (search != null && search.trim().isNotEmpty) {
      final term = '%${search.trim()}%';
      query = query.or('full_name.ilike.$term,company.ilike.$term,email.ilike.$term,phone.ilike.$term');
    }

    final response = await query.order('created_at', ascending: false).limit(limit);
    return (response as List<dynamic>).map((row) => CrmLead.fromJson(row as Map<String, dynamic>)).toList();
  }

  @override
  Future<CrmLead> createLead({
    required String venueId,
    required String fullName,
    String? email,
    String? phone,
    String? company,
    String? source,
    int? estimatedValueCents,
  }) async {
    final response = await _client
        .from('crm_leads')
        .insert({
          'venue_id': venueId,
          'full_name': fullName,
          if (email != null) 'email': email,
          if (phone != null) 'phone': phone,
          if (company != null) 'company': company,
          if (source != null) 'source': source,
          if (estimatedValueCents != null) 'estimated_value_cents': estimatedValueCents,
        })
        .select()
        .single();
    return CrmLead.fromJson(response);
  }

  @override
  Future<void> updateLeadStatus({required String leadId, required String status}) async {
    await _client.from('crm_leads').update({'status': status}).eq('id', leadId);
  }

  @override
  Future<List<CrmNote>> getNotes({required String leadId}) async {
    final response = await _client
        .from('crm_notes')
        .select()
        .eq('lead_id', leadId)
        .order('created_at', ascending: false)
        .limit(50);
    return (response as List<dynamic>).map((row) => CrmNote.fromJson(row as Map<String, dynamic>)).toList();
  }

  @override
  Future<void> addNote({required String leadId, required String text}) async {
    await _client.from('crm_notes').insert({'lead_id': leadId, 'text': text});
  }

  @override
  Future<List<CrmActivityLogEntry>> getActivity({required String leadId, int limit = 50}) async {
    final response = await _client
        .from('crm_activity_log')
        .select()
        .eq('lead_id', leadId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (response as List<dynamic>)
        .map((row) => CrmActivityLogEntry.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<CrmBeo>> getBeos({required String venueId, int limit = 100}) async {
    final response = await _client
        .from('crm_beos')
        .select()
        .eq('venue_id', venueId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (response as List<dynamic>).map((row) => CrmBeo.fromJson(row as Map<String, dynamic>)).toList();
  }

  @override
  Future<CrmBeo> createBeo({
    required String venueId,
    String? leadId,
    required String eventName,
    DateTime? eventDate,
    int? guestCount,
    String? venueSpace,
    int? depositCents,
  }) async {
    final response = await _client
        .from('crm_beos')
        .insert({
          'venue_id': venueId,
          if (leadId != null) 'lead_id': leadId,
          'event_name': eventName,
          if (eventDate != null) 'event_date': eventDate.toUtc().toIso8601String(),
          if (guestCount != null) 'guest_count': guestCount,
          if (venueSpace != null) 'venue_space': venueSpace,
          if (depositCents != null) 'deposit_cents': depositCents,
          if (depositCents != null && depositCents > 0) 'deposit_status': 'due',
        })
        .select()
        .single();
    return CrmBeo.fromJson(response);
  }

  @override
  Future<void> updateBeoStatus({required String beoId, required String status}) async {
    await _client.from('crm_beos').update({'status': status}).eq('id', beoId);
  }

  @override
  Future<bool> waiveBeoDeposit({required String beoId}) async {
    final response = await _client.rpc('waive_beo_deposit', params: {'p_beo_id': beoId});
    return response as bool;
  }

  @override
  Future<({String contractId, bool alreadyExisted})> convertBeoToContract({required String beoId}) async {
    final response = await _client.rpc('convert_beo_to_contract', params: {'p_beo_id': beoId});
    final row = (response as List<dynamic>).first as Map<String, dynamic>;
    return (contractId: row['contract_id'] as String, alreadyExisted: row['already_existed'] as bool);
  }

  @override
  Future<List<CrmContract>> getContracts({required String venueId, int limit = 100}) async {
    final response = await _client
        .from('crm_contracts')
        .select()
        .eq('venue_id', venueId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (response as List<dynamic>).map((row) => CrmContract.fromJson(row as Map<String, dynamic>)).toList();
  }

  @override
  Future<void> updateContractStatus({required String contractId, required String status}) async {
    await _client.from('crm_contracts').update({'status': status}).eq('id', contractId);
  }

  @override
  Future<List<CrmForecastRow>> getForecast({required String venueId}) async {
    final response = await _client.rpc('crm_pipeline_forecast', params: {'p_venue_id': venueId});
    return (response as List<dynamic>).map((row) => CrmForecastRow.fromJson(row as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<CrmStaleLead>> getStaleLeads({required String venueId, int days = 5}) async {
    final response =
        await _client.rpc('crm_stale_leads', params: {'p_venue_id': venueId, 'p_days': days});
    return (response as List<dynamic>).map((row) => CrmStaleLead.fromJson(row as Map<String, dynamic>)).toList();
  }
}
