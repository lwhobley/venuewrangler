import { ForbiddenException } from '@nestjs/common';

export function restaurantCoreOnly() {
  return process.env.RESTAURANT_CORE_ONLY === 'true' || process.env.RESTAURANT_CORE_ONLY === '1';
}

export function assertFullVenueEdition(feature: string) {
  if (restaurantCoreOnly()) throw new ForbiddenException(`${feature} is not available in the restaurant edition`);
}
