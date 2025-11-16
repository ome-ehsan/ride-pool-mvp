export interface User {
  id: string;
  email: string;
  phone?: string;
  gender?: 'MALE' | 'FEMALE';
}

export interface Location {
  latitude: number;
  longitude: number;
}

export interface Pool {
  id: string;
  driver_id: string;
  vehicle_type: 'CAR' | 'CNG';
  status: string;
  current_passengers: number;
  max_passengers: number;
  destination: Location;
}

export interface Ride {
  id: string;
  user_id: string;
  pool_id?: string;
  pickup: Location;
  dropoff: Location;
  status: string;
  fare?: number;
}