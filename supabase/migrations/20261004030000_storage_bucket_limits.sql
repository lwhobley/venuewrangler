-- Fix MEDIUM: direct-upload buckets had no size or MIME limits (cost abuse /
-- malware hosting). Staff-documents content is validated by documents-upload's
-- magic-byte check; these buckets are raw member uploads, so cap them here.
-- chat carries DM attachments: images + common docs, 15MB.

update storage.buckets set
  file_size_limit = 15728640,
  allowed_mime_types = array[
    'image/jpeg', 'image/png', 'image/webp',
    'application/pdf',
    'text/plain', 'text/csv',
    'application/rtf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation'
  ]
where id = 'chat';

update storage.buckets set
  file_size_limit = 15728640,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
where id in ('incident-evidence', 'checklist-evidence');

-- staff-documents is service-role-only (no direct authenticated insert after
-- 20261003003000); keep the 10MB cap as defense-in-depth matching MAX_DOCUMENT_BYTES.
update storage.buckets set
  file_size_limit = 10485760,
  allowed_mime_types = array[
    'application/pdf',
    'image/jpeg', 'image/png', 'image/webp',
    'text/plain', 'text/csv',
    'application/rtf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation'
  ]
where id = 'staff-documents';
