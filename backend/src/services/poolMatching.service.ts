import { Location } from '../types';
import { calculateDistance } from '../utils/helpers';
import { CONSTANTS } from '../config/constants';

export class PoolMatchingService {
  async findMatchingPools(
    pickup: Location,
    destination: Location,
    userId: string
  ) {
    // TODO: Implement pool matching logic
    return [];
  }

  isWithinPickupRange(location1: Location, location2: Location): boolean {
    const distance = calculateDistance(
      location1.latitude,
      location1.longitude,
      location2.latitude,
      location2.longitude
    );
    return distance <= CONSTANTS.PICKUP_RANGE_KM;
  }
}

export const poolMatchingService = new PoolMatchingService();