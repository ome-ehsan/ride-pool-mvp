export class FareService {
  calculateBaseFare(distance: number, vehicleType: string): number {
    // TODO: Implement fare calculation logic
    const baseRate = vehicleType === 'CAR' ? 50 : 30;
    return baseRate + distance * 15;
  }

  applyPoolDiscount(baseFare: number, passengerCount: number): number {
    const discountRate = passengerCount >= 3 ? 0.4 : 0.25;
    return baseFare * (1 - discountRate);
  }
}

export const fareService = new FareService();
