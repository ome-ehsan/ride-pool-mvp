export const SUPABASE_URL = process.env.SUPABASE_URL || '';
export const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || '';
export const API_BASE_URL = process.env.API_BASE_URL || 'http://localhost:3000/api';
export const GOOGLE_MAPS_API_KEY = process.env.GOOGLE_MAPS_API_KEY || '';

export const VEHICLE_TYPES = {
  CAR: 'CAR',
  CNG: 'CNG',
};

export const RIDE_STATUS = {
  REQUESTED: 'REQUESTED',
  MATCHED: 'MATCHED',
  STARTED: 'STARTED',
  COMPLETED: 'COMPLETED',
  CANCELLED: 'CANCELLED',
};
