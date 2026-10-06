import type { MediaAccessService } from '../chat/media-access.service';

export function profilePhotoUrl(
  profile: { id: string; venueId: string | null; photoKey?: string | null },
  mediaAccess: MediaAccessService,
): string | null {
  if (!profile.photoKey) return null;
  return mediaAccess.createPath(
    'profile-photo', `${profile.id}:${profile.photoKey}`, profile.venueId ?? profile.id,
    `/v1/app/profile-photos/${encodeURIComponent(profile.id)}`,
  );
}
