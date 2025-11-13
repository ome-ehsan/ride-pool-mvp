import { Location } from '../types';

export class RouteService {
  async optimizeRoute(stops: Location[]) {
    // TODO: Implement route optimization
    return stops;
  }

  async calculateETA(from: Location, to: Location): Promise<number> {
    // TODO: Implement ETA calculation
    return 0;
  }
}

export const routeService = new RouteService();