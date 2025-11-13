import { Location } from '../types';

export class GeolocationService {
  async validateLocation(location: Location): Promise<boolean> {
    // TODO: Implement location validation
    return true;
  }

  async calculateRoute(pickup: Location, dropoff: Location) {
    // TODO: Implement route calculation using Google Maps API
    return null;
  }
}

export const geolocationService = new GeolocationService();
