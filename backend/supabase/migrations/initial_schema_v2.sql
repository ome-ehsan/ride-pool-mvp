-- ============================================
-- COMPLETE RIDEPOOL SCHEMA
-- Rider-Centric Pooling System with Scoring & Vehicle Tracking
-- ============================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS postgis;

-- ============================================
-- METADATA TABLE
-- ============================================
CREATE TABLE public.app_metadata (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  key VARCHAR(100) UNIQUE NOT NULL,
  value JSONB NOT NULL,
  description TEXT,
  category VARCHAR(50),
  is_public BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_app_metadata_key ON public.app_metadata(key);
CREATE INDEX idx_app_metadata_category ON public.app_metadata(category);

COMMENT ON TABLE public.app_metadata IS 'Application-wide metadata and configuration';

-- Insert default metadata
INSERT INTO public.app_metadata (key, value, description, category, is_public) VALUES
('app_version', '{"major": 1, "minor": 0, "patch": 0}'::JSONB, 'Current application version', 'system', TRUE),
('maintenance_mode', '{"enabled": false, "message": null}'::JSONB, 'Maintenance mode configuration', 'system', TRUE),
('feature_flags', '{"dynamic_pooling": true, "route_scoring": true, "priyo_sathi": true}'::JSONB, 'Feature toggle flags', 'features', FALSE),
('default_settings', '{"max_pool_size": 4, "max_waiting_time_minutes": 10, "default_search_radius_km": 5}'::JSONB, 'Default application settings', 'config', FALSE),
('payment_methods', '{"enabled": ["BKASH", "NAGAD", "ROCKET", "CARD", "CASH"]}'::JSONB, 'Available payment methods', 'payments', TRUE),
('vehicle_types', '{"car": {"max_passengers": 4, "base_fare": 50}, "cng": {"max_passengers": 3, "base_fare": 30}}'::JSONB, 'Vehicle type configurations', 'config', TRUE),
('route_scoring_config', '{"front_route_only": true, "max_route_deviation_percent": 30}'::JSONB, 'Route matching configuration', 'scoring', FALSE);

-- ============================================
-- USERS TABLE (extends Supabase auth.users)
-- ============================================
CREATE TABLE public.users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  phone VARCHAR(20) UNIQUE,
  gender VARCHAR(10) CHECK (gender IN ('MALE', 'FEMALE', 'OTHER')),
  gender_preference VARCHAR(20) CHECK (gender_preference IN ('FEMALE_ONLY', 'ANY')) DEFAULT 'ANY',
  is_verified BOOLEAN DEFAULT FALSE,
  is_driver BOOLEAN DEFAULT FALSE,
  driver_verified_at TIMESTAMP WITH TIME ZONE,
  driver_priority_destination_lat DECIMAL(10, 8),
  driver_priority_destination_lng DECIMAL(11, 8),
  driver_priority_destination_location GEOGRAPHY(POINT, 4326),
  driver_priority_destination_address TEXT,
  average_rating DECIMAL(3,2),
  total_ratings INTEGER DEFAULT 0,
  total_rides INTEGER DEFAULT 0,
  deleted_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  CONSTRAINT phone_format CHECK (phone ~ '^\+880[0-9]{10}$' OR phone IS NULL)
);

CREATE INDEX idx_users_phone ON public.users(phone) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_is_driver ON public.users(is_driver) WHERE deleted_at IS NULL AND is_driver = TRUE;
CREATE INDEX idx_users_deleted_at ON public.users(deleted_at);
CREATE INDEX idx_users_driver_priority_location ON public.users USING GIST(driver_priority_destination_location) 
  WHERE is_driver = TRUE AND driver_priority_destination_location IS NOT NULL;

COMMENT ON TABLE public.users IS 'Extended user profiles with driver capabilities and priority destinations';
COMMENT ON COLUMN public.users.gender_preference IS 'Rider preference: FEMALE_ONLY or ANY (male riders default to ANY)';

-- ============================================
-- VEHICLES TABLE
-- ============================================
CREATE TABLE public.vehicles (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  driver_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  vehicle_type VARCHAR(10) NOT NULL CHECK (vehicle_type IN ('CAR', 'CNG')),
  vehicle_number VARCHAR(20) UNIQUE NOT NULL,
  model VARCHAR(100),
  color VARCHAR(50),
  max_passengers INTEGER NOT NULL DEFAULT 4 CHECK (max_passengers > 0 AND max_passengers <= 8),
  is_active BOOLEAN DEFAULT TRUE,
  deleted_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_vehicles_driver_id ON public.vehicles(driver_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_vehicles_is_active ON public.vehicles(is_active) WHERE deleted_at IS NULL AND is_active = TRUE;
CREATE INDEX idx_vehicles_deleted_at ON public.vehicles(deleted_at);

COMMENT ON TABLE public.vehicles IS 'Vehicles registered by drivers';

-- ============================================
-- VEHICLE LOCATIONS TABLE (Real-time Tracking)
-- ============================================
CREATE TABLE public.vehicle_locations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  vehicle_id UUID NOT NULL REFERENCES public.vehicles(id) ON DELETE CASCADE,
  driver_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  pool_id UUID REFERENCES public.pools(id) ON DELETE SET NULL,
  
  -- Current location
  current_lat DECIMAL(10, 8) NOT NULL,
  current_lng DECIMAL(11, 8) NOT NULL,
  current_location GEOGRAPHY(POINT, 4326),
  
  -- Movement data
  heading DECIMAL(5, 2), -- Bearing in degrees (0-360)
  speed_kmh DECIMAL(5, 2), -- Speed in km/h
  accuracy_meters INTEGER, -- GPS accuracy
  
  -- Status
  is_active BOOLEAN DEFAULT TRUE,
  is_available BOOLEAN DEFAULT TRUE, -- Available for new pool assignments
  
  -- Timestamps
  recorded_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  CONSTRAINT valid_heading CHECK (heading IS NULL OR (heading >= 0 AND heading < 360)),
  CONSTRAINT valid_speed CHECK (speed_kmh IS NULL OR speed_kmh >= 0)
);

CREATE INDEX idx_vehicle_locations_vehicle_id ON public.vehicle_locations(vehicle_id);
CREATE INDEX idx_vehicle_locations_driver_id ON public.vehicle_locations(driver_id);
CREATE INDEX idx_vehicle_locations_pool_id ON public.vehicle_locations(pool_id) WHERE pool_id IS NOT NULL;
CREATE INDEX idx_vehicle_locations_location ON public.vehicle_locations USING GIST(current_location) 
  WHERE is_active = TRUE;
CREATE INDEX idx_vehicle_locations_active ON public.vehicle_locations(vehicle_id, is_active) 
  WHERE is_active = TRUE;
CREATE INDEX idx_vehicle_locations_available ON public.vehicle_locations(is_available, is_active) 
  WHERE is_available = TRUE AND is_active = TRUE;

COMMENT ON TABLE public.vehicle_locations IS 'Real-time vehicle location tracking for active drivers';

-- ============================================
-- POOL SCORING CONFIGURATION TABLE
-- ============================================
CREATE TABLE public.pool_scoring_config (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  config_name VARCHAR(100) UNIQUE NOT NULL,
  min_viable_score DECIMAL(5,2) NOT NULL DEFAULT 60.00 CHECK (min_viable_score >= 0 AND min_viable_score <= 100),
  
  -- Scoring weights (must sum to 100)
  destination_proximity_weight DECIMAL(5,2) DEFAULT 30.00,
  pickup_proximity_weight DECIMAL(5,2) DEFAULT 25.00,
  route_overlap_weight DECIMAL(5,2) DEFAULT 20.00,
  time_alignment_weight DECIMAL(5,2) DEFAULT 15.00,
  detour_penalty_weight DECIMAL(5,2) DEFAULT 10.00,
  
  -- Distance thresholds (in kilometers)
  max_destination_distance_km DECIMAL(5,2) DEFAULT 2.00,
  max_pickup_distance_km DECIMAL(5,2) DEFAULT 5.00,
  min_route_overlap_percent DECIMAL(5,2) DEFAULT 40.00,
  max_detour_percent DECIMAL(5,2) DEFAULT 30.00,
  max_time_difference_minutes INTEGER DEFAULT 10,
  
  -- Front route constraint
  front_route_only BOOLEAN DEFAULT TRUE,
  max_off_route_distance_km DECIMAL(5,2) DEFAULT 0.5,
  
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  CONSTRAINT valid_weights CHECK (
    destination_proximity_weight + 
    pickup_proximity_weight + 
    route_overlap_weight + 
    time_alignment_weight + 
    detour_penalty_weight = 100
  )
);

-- Insert default configuration
INSERT INTO public.pool_scoring_config (
  config_name,
  min_viable_score,
  destination_proximity_weight,
  pickup_proximity_weight,
  route_overlap_weight,
  time_alignment_weight,
  detour_penalty_weight,
  max_destination_distance_km,
  max_pickup_distance_km,
  min_route_overlap_percent,
  max_detour_percent,
  max_time_difference_minutes,
  front_route_only,
  max_off_route_distance_km
) VALUES (
  'default',
  60.00,  -- Minimum 60% score to form pool
  30.00,  -- Destination proximity: 30%
  25.00,  -- Pickup proximity: 25%
  20.00,  -- Route overlap: 20%
  15.00,  -- Time alignment: 15%
  10.00,  -- Detour penalty: 10%
  2.00,   -- Max 2km destination difference
  5.00,   -- Max 5km pickup difference
  40.00,  -- Min 40% route overlap
  30.00,  -- Max 30% detour
  10,     -- Max 10 minutes time difference
  TRUE,   -- Only consider front-route passengers
  0.5     -- Max 500m off-route distance
);

COMMENT ON TABLE public.pool_scoring_config IS 'Configurable scoring system for pool viability assessment';
COMMENT ON COLUMN public.pool_scoring_config.front_route_only IS 'When true, only passengers on the direct route are considered for pooling';

-- ============================================
-- POOLS TABLE (Rider-Centric)
-- ============================================
CREATE TABLE public.pools (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  creator_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  driver_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  vehicle_id UUID REFERENCES public.vehicles(id) ON DELETE SET NULL,
  status VARCHAR(20) NOT NULL CHECK (status IN (
    'WAITING_FOR_RIDERS',    -- Pool created, waiting for min 2 riders
    'WAITING_FOR_DRIVER',    -- Has 2+ riders, waiting for driver
    'READY_TO_START',        -- Has 2+ riders + driver
    'STARTED',               -- Trip in progress
    'COMPLETED', 
    'CANCELLED'
  )) DEFAULT 'WAITING_FOR_RIDERS',
  
  -- Pool configuration (from first rider's request)
  destination_lat DECIMAL(10, 8) NOT NULL,
  destination_lng DECIMAL(11, 8) NOT NULL,
  destination_location GEOGRAPHY(POINT, 4326),
  destination_address TEXT,
  vehicle_type VARCHAR(10) NOT NULL CHECK (vehicle_type IN ('CAR', 'CNG')),
  gender_restriction VARCHAR(20) CHECK (gender_restriction IN ('FEMALE_ONLY', 'ANY')) DEFAULT 'ANY',
  
  -- Pool capacity tracking
  current_passengers INTEGER NOT NULL DEFAULT 0 CHECK (current_passengers >= 0),
  max_passengers INTEGER NOT NULL DEFAULT 4 CHECK (max_passengers > 0),
  min_passengers_to_start INTEGER NOT NULL DEFAULT 2 CHECK (min_passengers_to_start >= 1),
  
  -- Route information for dynamic matching
  hexagon_region_id VARCHAR(50), -- H3 or custom hexagon ID
  route_polyline TEXT, -- Encoded polyline for route matching
  
  -- Scoring information
  viability_score DECIMAL(5,2),
  score_breakdown JSONB,
  scoring_config_id UUID REFERENCES public.pool_scoring_config(id),
  
  -- Timing
  estimated_departure TIMESTAMP WITH TIME ZONE,
  estimated_arrival TIMESTAMP WITH TIME ZONE,
  fare_per_person DECIMAL(10, 2),
  
  -- Lifecycle timestamps
  deleted_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  started_at TIMESTAMP WITH TIME ZONE,
  completed_at TIMESTAMP WITH TIME ZONE,
  
  CONSTRAINT pool_capacity CHECK (current_passengers <= max_passengers),
  CONSTRAINT pool_min_capacity CHECK (min_passengers_to_start <= max_passengers),
  CONSTRAINT pool_times CHECK (
    (started_at IS NULL OR completed_at IS NULL OR completed_at > started_at) AND
    (created_at IS NULL OR started_at IS NULL OR started_at >= created_at)
  ),
  CONSTRAINT pool_driver_required_when_started CHECK (
    status NOT IN ('STARTED', 'COMPLETED') OR driver_id IS NOT NULL
  )
);

CREATE INDEX idx_pools_destination_location ON public.pools USING GIST(destination_location) 
  WHERE deleted_at IS NULL AND status IN ('WAITING_FOR_RIDERS', 'WAITING_FOR_DRIVER', 'READY_TO_START');
CREATE INDEX idx_pools_creator_user_id ON public.pools(creator_user_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_pools_driver_id ON public.pools(driver_id) WHERE deleted_at IS NULL AND driver_id IS NOT NULL;
CREATE INDEX idx_pools_status ON public.pools(status) WHERE deleted_at IS NULL;
CREATE INDEX idx_pools_vehicle_type_status_gender ON public.pools(vehicle_type, status, gender_restriction) 
  WHERE deleted_at IS NULL AND status IN ('WAITING_FOR_RIDERS', 'WAITING_FOR_DRIVER', 'READY_TO_START');
CREATE INDEX idx_pools_hexagon_region ON public.pools(hexagon_region_id) 
  WHERE deleted_at IS NULL AND hexagon_region_id IS NOT NULL;
CREATE INDEX idx_pools_viability_score ON public.pools(viability_score) 
  WHERE deleted_at IS NULL AND viability_score IS NOT NULL;
CREATE INDEX idx_pools_created_at ON public.pools(created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_pools_deleted_at ON public.pools(deleted_at);

COMMENT ON TABLE public.pools IS 'Rider-centric rideshare pools - each rider creates/joins a pool';
COMMENT ON COLUMN public.pools.viability_score IS 'Overall pool formation score (0-100) based on scoring system';

-- ============================================
-- RIDES TABLE (Individual Rider Requests)
-- ============================================
CREATE TABLE public.rides (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  pool_id UUID REFERENCES public.pools(id) ON DELETE SET NULL,
  
  -- Pickup details
  pickup_lat DECIMAL(10, 8) NOT NULL,
  pickup_lng DECIMAL(11, 8) NOT NULL,
  pickup_location GEOGRAPHY(POINT, 4326),
  pickup_address TEXT,
  
  -- Dropoff details
  dropoff_lat DECIMAL(10, 8) NOT NULL,
  dropoff_lng DECIMAL(11, 8) NOT NULL,
  dropoff_location GEOGRAPHY(POINT, 4326),
  dropoff_address TEXT,
  
  -- Rider preferences
  preferred_vehicle_type VARCHAR(10) NOT NULL CHECK (preferred_vehicle_type IN ('CAR', 'CNG')),
  preferred_gender_restriction VARCHAR(20) CHECK (preferred_gender_restriction IN ('FEMALE_ONLY', 'ANY')) DEFAULT 'ANY',
  
  -- Ride details
  status VARCHAR(20) NOT NULL CHECK (status IN (
    'CREATING_POOL',         -- Rider submitted, system creating/finding pool
    'IN_POOL',               -- Matched to a pool, waiting
    'DRIVER_ASSIGNED',       -- Pool has driver
    'STARTED',               -- Trip started
    'COMPLETED', 
    'CANCELLED'
  )) DEFAULT 'CREATING_POOL',
  
  fare DECIMAL(10, 2),
  distance_km DECIMAL(10, 2),
  estimated_pickup TIMESTAMP WITH TIME ZONE,
  
  -- Route position tracking
  is_on_front_route BOOLEAN DEFAULT TRUE, -- Whether rider is on the direct route to destination
  route_deviation_km DECIMAL(5, 2), -- How far off the main route
  
  -- Walking distance for dynamic pooling
  walking_distance_meters INTEGER, -- Distance rider needs to walk to join moving pool
  
  -- Lifecycle timestamps
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  started_at TIMESTAMP WITH TIME ZONE,
  completed_at TIMESTAMP WITH TIME ZONE,
  cancelled_reason TEXT,
  
  CONSTRAINT ride_times CHECK (
    completed_at IS NULL OR started_at IS NULL OR completed_at > started_at
  )
);

CREATE INDEX idx_rides_pickup_location ON public.rides USING GIST(pickup_location);
CREATE INDEX idx_rides_dropoff_location ON public.rides USING GIST(dropoff_location);
CREATE INDEX idx_rides_user_id ON public.rides(user_id);
CREATE INDEX idx_rides_pool_id ON public.rides(pool_id) WHERE pool_id IS NOT NULL;
CREATE INDEX idx_rides_status ON public.rides(status);
CREATE INDEX idx_rides_user_status ON public.rides(user_id, status);
CREATE INDEX idx_rides_is_on_front_route ON public.rides(is_on_front_route) WHERE is_on_front_route = TRUE;
CREATE INDEX idx_rides_created_at ON public.rides(created_at DESC);
CREATE INDEX idx_rides_pool_status ON public.rides(pool_id, status) WHERE pool_id IS NOT NULL;

COMMENT ON TABLE public.rides IS 'Individual ride requests from passengers';
COMMENT ON COLUMN public.rides.is_on_front_route IS 'TRUE if rider is on the direct route to destination (front-route passenger)';

-- ============================================
-- POOL_MEMBERS TABLE
-- ============================================
CREATE TABLE public.pool_members (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  pool_id UUID NOT NULL REFERENCES public.pools(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  ride_id UUID NOT NULL REFERENCES public.rides(id) ON DELETE CASCADE,
  seat_number INTEGER,
  joined_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  left_at TIMESTAMP WITH TIME ZONE,
  join_type VARCHAR(20) CHECK (join_type IN ('INITIAL', 'DYNAMIC')) DEFAULT 'INITIAL',
  join_score DECIMAL(5,2),
  join_score_breakdown JSONB,
  is_front_route_passenger BOOLEAN DEFAULT TRUE,
  UNIQUE(pool_id, user_id),
  UNIQUE(ride_id)
);

CREATE INDEX idx_pool_members_pool_id ON public.pool_members(pool_id);
CREATE INDEX idx_pool_members_user_id ON public.pool_members(user_id);
CREATE INDEX idx_pool_members_ride_id ON public.pool_members(ride_id);
CREATE INDEX idx_pool_members_pool_active ON public.pool_members(pool_id) WHERE left_at IS NULL;
CREATE INDEX idx_pool_members_front_route ON public.pool_members(pool_id, is_front_route_passenger) 
  WHERE is_front_route_passenger = TRUE AND left_at IS NULL;

COMMENT ON TABLE public.pool_members IS 'Junction table tracking pool membership with join types and route position';
COMMENT ON COLUMN public.pool_members.is_front_route_passenger IS 'Whether this passenger is on the direct front route';

-- ============================================
-- POOL_DRIVER_ASSIGNMENTS TABLE
-- ============================================
CREATE TABLE public.pool_driver_assignments (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  pool_id UUID NOT NULL REFERENCES public.pools(id) ON DELETE CASCADE,
  driver_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  vehicle_id UUID NOT NULL REFERENCES public.vehicles(id) ON DELETE RESTRICT,
  status VARCHAR(20) NOT NULL CHECK (status IN ('SELECTED', 'REJECTED', 'CANCELLED', 'COMPLETED')) DEFAULT 'SELECTED',
  selected_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  rejected_at TIMESTAMP WITH TIME ZONE,
  rejection_reason TEXT
);

CREATE INDEX idx_pool_driver_assignments_pool_id ON public.pool_driver_assignments(pool_id);
CREATE INDEX idx_pool_driver_assignments_driver_id ON public.pool_driver_assignments(driver_id);
CREATE INDEX idx_pool_driver_assignments_status ON public.pool_driver_assignments(pool_id, status);

COMMENT ON TABLE public.pool_driver_assignments IS 'Tracks driver selection and assignment history for pools';

-- ============================================
-- PRIYO_SATHI (PREFERRED COMPANIONS) TABLE
-- ============================================
CREATE TABLE public.priyo_sathi (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  companion_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  status VARCHAR(20) NOT NULL CHECK (status IN ('PENDING', 'ACCEPTED', 'BLOCKED')) DEFAULT 'PENDING',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(user_id, companion_id),
  CHECK (user_id != companion_id)
);

CREATE INDEX idx_priyo_sathi_user_id ON public.priyo_sathi(user_id);
CREATE INDEX idx_priyo_sathi_companion_id ON public.priyo_sathi(companion_id);
CREATE INDEX idx_priyo_sathi_user_status ON public.priyo_sathi(user_id, status);

COMMENT ON TABLE public.priyo_sathi IS 'Preferred companions for safer shared rides';

-- ============================================
-- PAYMENTS TABLE
-- ============================================
CREATE TABLE public.payments (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ride_id UUID NOT NULL REFERENCES public.rides(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  amount DECIMAL(10, 2) NOT NULL CHECK (amount >= 0),
  payment_method VARCHAR(20) NOT NULL CHECK (payment_method IN ('BKASH', 'NAGAD', 'ROCKET', 'CARD', 'CASH')),
  status VARCHAR(20) NOT NULL CHECK (status IN ('PENDING', 'COMPLETED', 'FAILED', 'REFUNDED')) DEFAULT 'PENDING',
  transaction_id VARCHAR(100),
  metadata JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_payments_ride_id ON public.payments(ride_id);
CREATE INDEX idx_payments_user_id ON public.payments(user_id);
CREATE INDEX idx_payments_status ON public.payments(status);
CREATE INDEX idx_payments_transaction_id ON public.payments(transaction_id) WHERE transaction_id IS NOT NULL;

COMMENT ON TABLE public.payments IS 'Payment transactions for completed rides';

-- ============================================
-- RATINGS TABLE
-- ============================================
CREATE TABLE public.ratings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ride_id UUID NOT NULL REFERENCES public.rides(id) ON DELETE CASCADE,
  rater_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  rated_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment TEXT,
  tags TEXT[],
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(ride_id, rater_id, rated_id),
  CHECK (rater_id != rated_id)
);

CREATE INDEX idx_ratings_rated_id ON public.ratings(rated_id);
CREATE INDEX idx_ratings_rater_id ON public.ratings(rater_id);
CREATE INDEX idx_ratings_ride_id ON public.ratings(ride_id);

COMMENT ON TABLE public.ratings IS 'User ratings and reviews';

-- ============================================
-- NOTIFICATIONS TABLE
-- ============================================
CREATE TABLE public.notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  title VARCHAR(255) NOT NULL,
  message TEXT NOT NULL,
  type VARCHAR(50) NOT NULL,
  is_read BOOLEAN DEFAULT FALSE,
  metadata JSONB,
  action_url TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_notifications_user_id ON public.notifications(user_id);
CREATE INDEX idx_notifications_user_unread ON public.notifications(user_id, is_read) WHERE is_read = FALSE;
CREATE INDEX idx_notifications_created_at ON public.notifications(created_at DESC);
CREATE INDEX idx_notifications_type ON public.notifications(type);

COMMENT ON TABLE public.notifications IS 'User notifications and alerts';

-- ============================================
-- TRIGGERS FOR UPDATED_AT
-- ============================================
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_app_metadata_updated_at BEFORE UPDATE ON public.app_metadata
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_vehicles_updated_at BEFORE UPDATE ON public.vehicles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_vehicle_locations_updated_at BEFORE UPDATE ON public.vehicle_locations
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_pool_scoring_config_updated_at BEFORE UPDATE ON public.pool_scoring_config
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_pools_updated_at BEFORE UPDATE ON public.pools
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_rides_updated_at BEFORE UPDATE ON public.rides
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_payments_updated_at BEFORE UPDATE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_priyo_sathi_updated_at BEFORE UPDATE ON public.priyo_sathi
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- GEOGRAPHY TRIGGERS
-- ============================================
CREATE OR REPLACE FUNCTION update_pool_geography()
RETURNS TRIGGER AS $$
BEGIN
  NEW.destination_location = ST_SetSRID(
    ST_MakePoint(NEW.destination_lng, NEW.destination_lat), 
    4326
  )::geography;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_pool_geography_trigger
BEFORE INSERT OR UPDATE OF destination_lat, destination_lng ON public.pools
FOR EACH ROW
EXECUTE FUNCTION update_pool_geography();

CREATE OR REPLACE FUNCTION update_ride_geography()
RETURNS TRIGGER AS $$
BEGIN
  NEW.pickup_location = ST_SetSRID(
    ST_MakePoint(NEW.pickup_lng, NEW.pickup_lat), 
    4326
  )::geography;
  NEW.dropoff_location = ST_SetSRID(
    ST_MakePoint(NEW.dropoff_lng, NEW.dropoff_lat), 
    4326
  )::geography;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_ride_geography_trigger
BEFORE INSERT OR UPDATE OF pickup_lat, pickup_lng, dropoff_lat, dropoff_lng ON public.rides
FOR EACH ROW
EXECUTE FUNCTION update_ride_geography();

CREATE OR REPLACE FUNCTION update_user_driver_priority_geography()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.driver_priority_destination_lat IS NOT NULL AND NEW.driver_priority_destination_lng IS NOT NULL THEN
    NEW.driver_priority_destination_location = ST_SetSRID(
      ST_MakePoint(NEW.driver_priority_destination_lng, NEW.driver_priority_destination_lat), 
      4326
    )::geography;
  ELSE
    NEW.driver_priority_destination_location = NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_user_driver_priority_geography_trigger
BEFORE INSERT OR UPDATE OF driver_priority_destination_lat, driver_priority_destination_lng ON public.users
FOR EACH ROW
EXECUTE FUNCTION update_user_driver_priority_geography();

CREATE OR REPLACE FUNCTION update_vehicle_location_geography()
RETURNS TRIGGER AS $$
BEGIN
  NEW.current_location = ST_SetSRID(
    ST_MakePoint(NEW.current_lng, NEW.current_lat), 
    4326
  )::geography;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_vehicle_location_geography_trigger
BEFORE INSERT OR UPDATE OF current_lat, current_lng ON public.vehicle_locations
FOR EACH ROW
EXECUTE FUNCTION update_vehicle_location_geography();

-- ============================================
-- ROUTE POSITION TRIGGER (Front-Route Detection)
-- ============================================
CREATE OR REPLACE FUNCTION update_ride_route_position()
RETURNS TRIGGER AS $$
DECLARE
  v_pool RECORD;
  v_direct_distance DECIMAL;
  v_route_distance DECIMAL;
  v_deviation DECIMAL;
  v_config RECORD;
BEGIN
  IF NEW.pool_id IS NULL THEN
    NEW.is_on_front_route = TRUE;
    NEW.route_deviation_km = 0;
    RETURN NEW;
  END IF;
  
  -- Get pool and config
  SELECT p.*, c.front_route_only, c.max_off_route_distance_km
  INTO v_pool
  FROM public.pools p
  LEFT JOIN public.pool_scoring_config c ON c.id = p.scoring_config_id
  WHERE p.id = NEW.pool_id;
  
  -- Calculate direct distance from pool origin to destination
  v_direct_distance := ST_Distance(
    v_pool.destination_location,
    (SELECT pickup_location FROM public.rides 
     WHERE pool_id = NEW.pool_id 
     ORDER BY created_at ASC LIMIT 1)
  ) / 1000;
  
  -- Calculate distance via this ride's pickup
  v_route_distance := (
    ST_Distance(
      (SELECT pickup_location FROM public.rides 
       WHERE pool_id = NEW.pool_id 
       ORDER BY created_at ASC LIMIT 1),
      NEW.pickup_location
    ) +
    ST_Distance(NEW.pickup_location, v_pool.destination_location)
  ) / 1000;
  
  -- Calculate deviation
  v_deviation := v_route_distance - v_direct_distance;
  NEW.route_deviation_km = v_deviation;
  
  -- Determine if on front route
  IF v_pool.front_route_only THEN
    NEW.is_on_front_route = (v_deviation <= COALESCE(v_pool.max_off_route_distance_km, 0.5));
  ELSE
    NEW.is_on_front_route = TRUE;
  END IF;
  
  RETURN NEW;
END;
$ LANGUAGE plpgsql;

CREATE TRIGGER update_ride_route_position_trigger
BEFORE INSERT OR UPDATE OF pool_id, pickup_lat, pickup_lng ON public.rides
FOR EACH ROW
EXECUTE FUNCTION update_ride_route_position();

COMMENT ON TRIGGER update_ride_route_position_trigger ON public.rides IS 'Automatically determines if ride is on front route';

-- ============================================
-- BUSINESS LOGIC TRIGGERS
-- ============================================

-- Sync pool passenger count and status (only count front-route passengers)
CREATE OR REPLACE FUNCTION sync_pool_status()
RETURNS TRIGGER AS $
DECLARE
  v_pool_id UUID;
  v_count INTEGER;
  v_max_passengers INTEGER;
  v_min_passengers INTEGER;
  v_has_driver BOOLEAN;
  v_current_status VARCHAR;
  v_front_route_only BOOLEAN;
BEGIN
  v_pool_id = COALESCE(NEW.pool_id, OLD.pool_id);
  
  -- Get pool info
  SELECT 
    p.max_passengers, 
    p.min_passengers_to_start,
    (p.driver_id IS NOT NULL),
    p.status,
    COALESCE(c.front_route_only, TRUE)
  INTO v_max_passengers, v_min_passengers, v_has_driver, v_current_status, v_front_route_only
  FROM public.pools p
  LEFT JOIN public.pool_scoring_config c ON c.id = p.scoring_config_id
  WHERE p.id = v_pool_id;
  
  -- Count current active members (only front-route if configured)
  IF v_front_route_only THEN
    SELECT COUNT(*) INTO v_count
    FROM public.pool_members pm
    WHERE pm.pool_id = v_pool_id 
      AND pm.left_at IS NULL
      AND pm.is_front_route_passenger = TRUE;
  ELSE
    SELECT COUNT(*) INTO v_count
    FROM public.pool_members pm
    WHERE pm.pool_id = v_pool_id AND pm.left_at IS NULL;
  END IF;
  
  -- Update pool status based on conditions
  UPDATE public.pools
  SET 
    current_passengers = v_count,
    status = CASE 
      -- Don't change if already started, completed, or cancelled
      WHEN status IN ('STARTED', 'COMPLETED', 'CANCELLED') THEN status
      -- Has enough riders + driver = ready to start
      WHEN v_count >= v_min_passengers AND v_has_driver THEN 'READY_TO_START'
      -- Has enough riders but no driver
      WHEN v_count >= v_min_passengers AND NOT v_has_driver THEN 'WAITING_FOR_DRIVER'
      -- Not enough riders yet
      ELSE 'WAITING_FOR_RIDERS'
    END
  WHERE id = v_pool_id;
  
  RETURN COALESCE(NEW, OLD);
END;
$ LANGUAGE plpgsql;

CREATE TRIGGER sync_pool_status_on_member_change
AFTER INSERT OR UPDATE OR DELETE ON public.pool_members
FOR EACH ROW
EXECUTE FUNCTION sync_pool_status();

-- Update pool status when driver is assigned
CREATE OR REPLACE FUNCTION sync_pool_status_on_driver_change()
RETURNS TRIGGER AS $
BEGIN
  PERFORM sync_pool_status_internal(NEW.id);
  RETURN NEW;
END;
$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sync_pool_status_internal(p_pool_id UUID)
RETURNS VOID AS $
DECLARE
  v_count INTEGER;
  v_max_passengers INTEGER;
  v_min_passengers INTEGER;
  v_has_driver BOOLEAN;
  v_front_route_only BOOLEAN;
BEGIN
  SELECT 
    p.max_passengers, 
    p.min_passengers_to_start,
    (p.driver_id IS NOT NULL),
    COALESCE(c.front_route_only, TRUE)
  INTO v_max_passengers, v_min_passengers, v_has_driver, v_front_route_only
  FROM public.pools p
  LEFT JOIN public.pool_scoring_config c ON c.id = p.scoring_config_id
  WHERE p.id = p_pool_id;
  
  -- Count active members (front-route only if configured)
  IF v_front_route_only THEN
    SELECT COUNT(*) INTO v_count
    FROM public.pool_members pm
    WHERE pm.pool_id = p_pool_id 
      AND pm.left_at IS NULL
      AND pm.is_front_route_passenger = TRUE;
  ELSE
    SELECT COUNT(*) INTO v_count
    FROM public.pool_members pm
    WHERE pm.pool_id = p_pool_id AND pm.left_at IS NULL;
  END IF;
  
  UPDATE public.pools
  SET 
    status = CASE 
      WHEN status IN ('STARTED', 'COMPLETED', 'CANCELLED') THEN status
      WHEN v_count >= v_min_passengers AND v_has_driver THEN 'READY_TO_START'
      WHEN v_count >= v_min_passengers AND NOT v_has_driver THEN 'WAITING_FOR_DRIVER'
      ELSE 'WAITING_FOR_RIDERS'
    END
  WHERE id = p_pool_id;
END;
$ LANGUAGE plpgsql;

CREATE TRIGGER sync_pool_status_on_driver_assignment
AFTER UPDATE OF driver_id ON public.pools
FOR EACH ROW
WHEN (OLD.driver_id IS DISTINCT FROM NEW.driver_id)
EXECUTE FUNCTION sync_pool_status_on_driver_change();

-- Cascade pool cancellation
CREATE OR REPLACE FUNCTION cascade_pool_cancellation()
RETURNS TRIGGER AS $
BEGIN
  IF NEW.status = 'CANCELLED' AND OLD.status != 'CANCELLED' THEN
    -- Cancel all active rides in this pool
    UPDATE public.rides
    SET 
      status = 'CANCELLED',
      cancelled_reason = 'Pool was cancelled'
    WHERE pool_id = NEW.id
    AND status NOT IN ('COMPLETED', 'CANCELLED');
    
    -- Mark all pool members as left
    UPDATE public.pool_members
    SET left_at = NOW()
    WHERE pool_id = NEW.id
    AND left_at IS NULL;
  END IF;
  
  RETURN NEW;
END;
$ LANGUAGE plpgsql;

CREATE TRIGGER cascade_pool_cancel
AFTER UPDATE OF status ON public.pools
FOR EACH ROW
WHEN (NEW.status = 'CANCELLED' AND OLD.status != 'CANCELLED')
EXECUTE FUNCTION cascade_pool_cancellation();

-- Update user ratings
CREATE OR REPLACE FUNCTION update_user_rating()
RETURNS TRIGGER AS $
BEGIN
  UPDATE public.users
  SET 
    average_rating = (
      SELECT ROUND(AVG(rating)::numeric, 2)
      FROM public.ratings
      WHERE rated_id = NEW.rated_id
    ),
    total_ratings = (
      SELECT COUNT(*)
      FROM public.ratings
      WHERE rated_id = NEW.rated_id
    )
  WHERE id = NEW.rated_id;
  
  RETURN NEW;
END;
$ LANGUAGE plpgsql;

CREATE TRIGGER update_user_rating_trigger
AFTER INSERT ON public.ratings
FOR EACH ROW
EXECUTE FUNCTION update_user_rating();

-- Update user ride count
CREATE OR REPLACE FUNCTION update_user_ride_count()
RETURNS TRIGGER AS $
BEGIN
  IF NEW.status = 'COMPLETED' AND OLD.status != 'COMPLETED' THEN
    UPDATE public.users
    SET total_rides = total_rides + 1
    WHERE id = NEW.user_id;
  END IF;
  
  RETURN NEW;
END;
$ LANGUAGE plpgsql;

CREATE TRIGGER update_user_ride_count_trigger
AFTER UPDATE OF status ON public.rides
FOR EACH ROW
WHEN (NEW.status = 'COMPLETED' AND OLD.status != 'COMPLETED')
EXECUTE FUNCTION update_user_ride_count();

-- ============================================
-- POOL SCORING TRIGGERS
-- ============================================

-- Auto-calculate pool score on formation (only for front-route passengers)
CREATE OR REPLACE FUNCTION update_pool_viability_score()
RETURNS TRIGGER AS $
DECLARE
  v_first_ride_id UUID;
  v_second_ride_id UUID;
  v_score_result RECORD;
  v_member_count INTEGER;
  v_front_route_only BOOLEAN;
BEGIN
  -- Get pool config
  SELECT COALESCE(c.front_route_only, TRUE)
  INTO v_front_route_only
  FROM public.pools p
  LEFT JOIN public.pool_scoring_config c ON c.id = p.scoring_config_id
  WHERE p.id = NEW.pool_id;
  
  -- Count front-route members if required
  IF v_front_route_only THEN
    SELECT COUNT(*) INTO v_member_count
    FROM public.pool_members
    WHERE pool_id = NEW.pool_id 
      AND left_at IS NULL
      AND is_front_route_passenger = TRUE;
  ELSE
    SELECT COUNT(*) INTO v_member_count
    FROM public.pool_members
    WHERE pool_id = NEW.pool_id AND left_at IS NULL;
  END IF;
  
  -- Only calculate when second member joins
  IF v_member_count = 2 THEN
    -- Get first two rides (front-route if required)
    IF v_front_route_only THEN
      SELECT ride_id INTO v_first_ride_id
      FROM public.pool_members
      WHERE pool_id = NEW.pool_id 
        AND left_at IS NULL
        AND is_front_route_passenger = TRUE
      ORDER BY joined_at ASC
      LIMIT 1 OFFSET 0;
      
      SELECT ride_id INTO v_second_ride_id
      FROM public.pool_members
      WHERE pool_id = NEW.pool_id 
        AND left_at IS NULL
        AND is_front_route_passenger = TRUE
      ORDER BY joined_at ASC
      LIMIT 1 OFFSET 1;
    ELSE
      SELECT ride_id INTO v_first_ride_id
      FROM public.pool_members
      WHERE pool_id = NEW.pool_id AND left_at IS NULL
      ORDER BY joined_at ASC
      LIMIT 1 OFFSET 0;
      
      SELECT ride_id INTO v_second_ride_id
      FROM public.pool_members
      WHERE pool_id = NEW.pool_id AND left_at IS NULL
      ORDER BY joined_at ASC
      LIMIT 1 OFFSET 1;
    END IF;
    
    -- Calculate score
    SELECT * INTO v_score_result
    FROM calculate_pool_viability_score(v_first_ride_id, v_second_ride_id);
    
    -- Update pool with score
    UPDATE public.pools
    SET 
      viability_score = v_score_result.total_score,
      score_breakdown = v_score_result.breakdown
    WHERE id = NEW.pool_id;
    
    -- Record score for the joining member
    UPDATE public.pool_members
    SET 
      join_score = v_score_result.total_score,
      join_score_breakdown = v_score_result.breakdown
    WHERE id = NEW.id;
    
    -- If score too low, cancel pool
    IF NOT v_score_result.is_viable THEN
      UPDATE public.pools
      SET 
        status = 'CANCELLED',
        deleted_at = NOW()
      WHERE id = NEW.pool_id;
      
      -- Notify users
      INSERT INTO public.notifications (user_id, title, message, type, metadata)
      SELECT 
        pm.user_id,
        'Pool Formation Failed',
        FORMAT('Pool cancelled: %s (Score: %.1f/100)', v_score_result.rejection_reason, v_score_result.total_score),
        'POOL_CANCELLED',
        jsonb_build_object('pool_id', NEW.pool_id, 'score', v_score_result.total_score)
      FROM public.pool_members pm
      WHERE pm.pool_id = NEW.pool_id;
    END IF;
  END IF;
  
  RETURN NEW;
END;
$ LANGUAGE plpgsql;

CREATE TRIGGER validate_pool_score_on_member_join
AFTER INSERT ON public.pool_members
FOR EACH ROW
EXECUTE FUNCTION update_pool_viability_score();

-- Update front-route status in pool_members when ride is updated
CREATE OR REPLACE FUNCTION sync_pool_member_route_status()
RETURNS TRIGGER AS $
BEGIN
  UPDATE public.pool_members
  SET is_front_route_passenger = NEW.is_on_front_route
  WHERE ride_id = NEW.id;
  
  RETURN NEW;
END;
$ LANGUAGE plpgsql;

CREATE TRIGGER sync_pool_member_route_status_trigger
AFTER UPDATE OF is_on_front_route ON public.rides
FOR EACH ROW
WHEN (OLD.is_on_front_route IS DISTINCT FROM NEW.is_on_front_route)
EXECUTE FUNCTION sync_pool_member_route_status();

-- ============================================
-- CORE SCORING FUNCTIONS
-- ============================================

-- Calculate destination proximity score (0-30 points)
CREATE OR REPLACE FUNCTION calculate_destination_proximity_score(
  distance_km DECIMAL,
  max_distance_km DECIMAL,
  weight DECIMAL
)
RETURNS DECIMAL AS $
BEGIN
  IF distance_km > max_distance_km THEN
    RETURN 0;
  END IF;
  
  RETURN weight * (1 - (distance_km / max_distance_km));
END;
$ LANGUAGE plpgsql IMMUTABLE;

-- Calculate pickup proximity score (0-25 points)
CREATE OR REPLACE FUNCTION calculate_pickup_proximity_score(
  distance_km DECIMAL,
  max_distance_km DECIMAL,
  weight DECIMAL
)
RETURNS DECIMAL AS $
BEGIN
  IF distance_km > max_distance_km THEN
    RETURN 0;
  END IF;
  
  RETURN weight * POWER(1 - (distance_km / max_distance_km), 2);
END;
$ LANGUAGE plpgsql IMMUTABLE;

-- Calculate route overlap score (0-20 points)
CREATE OR REPLACE FUNCTION calculate_route_overlap_score(
  overlap_percent DECIMAL,
  min_overlap_percent DECIMAL,
  weight DECIMAL
)
RETURNS DECIMAL AS $
BEGIN
  IF overlap_percent < min_overlap_percent THEN
    RETURN 0;
  END IF;
  
  RETURN weight * ((overlap_percent - min_overlap_percent) / (100 - min_overlap_percent));
END;
$ LANGUAGE plpgsql IMMUTABLE;

-- Calculate time alignment score (0-15 points)
CREATE OR REPLACE FUNCTION calculate_time_alignment_score(
  time_diff_minutes INTEGER,
  max_time_diff_minutes INTEGER,
  weight DECIMAL
)
RETURNS DECIMAL AS $
BEGIN
  IF time_diff_minutes > max_time_diff_minutes THEN
    RETURN 0;
  END IF;
  
  RETURN weight * (1 - (time_diff_minutes::DECIMAL / max_time_diff_minutes));
END;
$ LANGUAGE plpgsql IMMUTABLE;

-- Calculate detour penalty (0-10 points deduction)
CREATE OR REPLACE FUNCTION calculate_detour_penalty(
  detour_percent DECIMAL,
  max_detour_percent DECIMAL,
  weight DECIMAL
)
RETURNS DECIMAL AS $
BEGIN
  IF detour_percent > max_detour_percent THEN
    RETURN -weight;
  END IF;
  
  RETURN -weight * (detour_percent / max_detour_percent);
END;
$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================
-- MASTER SCORING FUNCTION
-- ============================================

CREATE OR REPLACE FUNCTION calculate_pool_viability_score(
  p_ride1_id UUID,
  p_ride2_id UUID,
  p_config_name VARCHAR DEFAULT 'default'
)
RETURNS TABLE (
  total_score DECIMAL,
  is_viable BOOLEAN,
  breakdown JSONB,
  rejection_reason TEXT
) AS $
DECLARE
  v_config RECORD;
  v_ride1 RECORD;
  v_ride2 RECORD;
  v_dest_distance_km DECIMAL;
  v_pickup_distance_km DECIMAL;
  v_route_overlap_percent DECIMAL;
  v_time_diff_minutes INTEGER;
  v_detour_percent DECIMAL;
  v_dest_score DECIMAL;
  v_pickup_score DECIMAL;
  v_overlap_score DECIMAL;
  v_time_score DECIMAL;
  v_detour_score DECIMAL;
  v_total_score DECIMAL;
  v_rejection_reason TEXT := NULL;
BEGIN
  -- Get configuration
  SELECT * INTO v_config
  FROM public.pool_scoring_config
  WHERE config_name = p_config_name AND is_active = TRUE
  LIMIT 1;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Scoring configuration "%" not found', p_config_name;
  END IF;
  
  -- Get ride details
  SELECT 
    pickup_lat, pickup_lng, pickup_location,
    dropoff_lat, dropoff_lng, dropoff_location,
    created_at, is_on_front_route
  INTO v_ride1
  FROM public.rides
  WHERE id = p_ride1_id;
  
  SELECT 
    pickup_lat, pickup_lng, pickup_location,
    dropoff_lat, dropoff_lng, dropoff_location,
    created_at, is_on_front_route
  INTO v_ride2
  FROM public.rides
  WHERE id = p_ride2_id;
  
  -- Check front-route requirement
  IF v_config.front_route_only AND (NOT v_ride1.is_on_front_route OR NOT v_ride2.is_on_front_route) THEN
    v_rejection_reason := 'One or both riders are not on the front route';
    RETURN QUERY SELECT 0::DECIMAL, FALSE, '{}'::JSONB, v_rejection_reason;
    RETURN;
  END IF;
  
  -- 1. DESTINATION PROXIMITY
  v_dest_distance_km := (ST_Distance(
    v_ride1.dropoff_location,
    v_ride2.dropoff_location
  ) / 1000)::DECIMAL;
  
  IF v_dest_distance_km > v_config.max_destination_distance_km THEN
    v_rejection_reason := FORMAT(
      'Destinations too far apart: %.2f km (max: %.2f km)',
      v_dest_distance_km,
      v_config.max_destination_distance_km
    );
  END IF;
  
  v_dest_score := calculate_destination_proximity_score(
    v_dest_distance_km,
    v_config.max_destination_distance_km,
    v_config.destination_proximity_weight
  );
  
  -- 2. PICKUP PROXIMITY
  v_pickup_distance_km := (ST_Distance(
    v_ride1.pickup_location,
    v_ride2.pickup_location
  ) / 1000)::DECIMAL;
  
  IF v_pickup_distance_km > v_config.max_pickup_distance_km THEN
    v_rejection_reason := COALESCE(v_rejection_reason || E'\n', '') || FORMAT(
      'Pickups too far apart: %.2f km (max: %.2f km)',
      v_pickup_distance_km,
      v_config.max_pickup_distance_km
    );
  END IF;
  
  v_pickup_score := calculate_pickup_proximity_score(
    v_pickup_distance_km,
    v_config.max_pickup_distance_km,
    v_config.pickup_proximity_weight
  );
  
  -- 3. ROUTE OVERLAP
  DECLARE
    v_direct_distance DECIMAL;
    v_combined_distance DECIMAL;
  BEGIN
    v_direct_distance := (ST_Distance(
      v_ride1.pickup_location,
      v_ride1.dropoff_location
    ) / 1000)::DECIMAL;
    
    v_combined_distance := (
      ST_Distance(v_ride1.pickup_location, v_ride2.pickup_location) +
      ST_Distance(v_ride2.pickup_location, v_ride2.dropoff_location) +
      ST_Distance(v_ride2.dropoff_location, v_ride1.dropoff_location)
    ) / 1000;
    
    v_route_overlap_percent := LEAST(100, (v_direct_distance / NULLIF(v_combined_distance, 0)) * 100);
  END;
  
  IF v_route_overlap_percent < v_config.min_route_overlap_percent THEN
    v_rejection_reason := COALESCE(v_rejection_reason || E'\n', '') || FORMAT(
      'Insufficient route overlap: %.1f%% (min: %.1f%%)',
      v_route_overlap_percent,
      v_config.min_route_overlap_percent
    );
  END IF;
  
  v_overlap_score := calculate_route_overlap_score(
    v_route_overlap_percent,
    v_config.min_route_overlap_percent,
    v_config.route_overlap_weight
  );
  
  -- 4. TIME ALIGNMENT
  v_time_diff_minutes := ABS(
    EXTRACT(EPOCH FROM (v_ride1.created_at - v_ride2.created_at)) / 60
  )::INTEGER;
  
  IF v_time_diff_minutes > v_config.max_time_difference_minutes THEN
    v_rejection_reason := COALESCE(v_rejection_reason || E'\n', '') || FORMAT(
      'Requests too far apart in time: %s minutes (max: %s minutes)',
      v_time_diff_minutes,
      v_config.max_time_difference_minutes
    );
  END IF;
  
  v_time_score := calculate_time_alignment_score(
    v_time_diff_minutes,
    v_config.max_time_difference_minutes,
    v_config.time_alignment_weight
  );
  
  -- 5. DETOUR PENALTY
  DECLARE
    v_direct_route_km DECIMAL;
    v_pooled_route_km DECIMAL;
  BEGIN
    v_direct_route_km := (ST_Distance(
      v_ride1.pickup_location,
      v_ride1.dropoff_location
    ) / 1000)::DECIMAL;
    
    v_pooled_route_km := (
      ST_Distance(v_ride1.pickup_location, v_ride2.pickup_location) +
      ST_Distance(v_ride2.pickup_location, v_ride2.dropoff_location) +
      ST_Distance(v_ride2.dropoff_location, v_ride1.dropoff_location)
    ) / 1000;
    
    v_detour_percent := ((v_pooled_route_km - v_direct_route_km) / NULLIF(v_direct_route_km, 0)) * 100;
  END;
  
  IF v_detour_percent > v_config.max_detour_percent THEN
    v_rejection_reason := COALESCE(v_rejection_reason || E'\n', '') || FORMAT(
      'Excessive detour: %.1f%% (max: %.1f%%)',
      v_detour_percent,
      v_config.max_detour_percent
    );
  END IF;
  
  v_detour_score := calculate_detour_penalty(
    v_detour_percent,
    v_config.max_detour_percent,
    v_config.detour_penalty_weight
  );
  
  -- CALCULATE TOTAL SCORE
  v_total_score := GREATEST(0, LEAST(100, 
    v_dest_score + v_pickup_score + v_overlap_score + v_time_score + v_detour_score
  ));
  
  RETURN QUERY SELECT
    v_total_score AS total_score,
    (v_total_score >= v_config.min_viable_score AND v_rejection_reason IS NULL) AS is_viable,
    jsonb_build_object(
      'destination_proximity', jsonb_build_object(
        'score', ROUND(v_dest_score, 2),
        'distance_km', ROUND(v_dest_distance_km, 2),
        'max_allowed_km', v_config.max_destination_distance_km
      ),
      'pickup_proximity', jsonb_build_object(
        'score', ROUND(v_pickup_score, 2),
        'distance_km', ROUND(v_pickup_distance_km, 2),
        'max_allowed_km', v_config.max_pickup_distance_km
      ),
      'route_overlap', jsonb_build_object(
        'score', ROUND(v_overlap_score, 2),
        'overlap_percent', ROUND(v_route_overlap_percent, 1),
        'min_required_percent', v_config.min_route_overlap_percent
      ),
      'time_alignment', jsonb_build_object(
        'score', ROUND(v_time_score, 2),
        'time_diff_minutes', v_time_diff_minutes,
        'max_allowed_minutes', v_config.max_time_difference_minutes
      ),
      'detour_penalty', jsonb_build_object(
        'score', ROUND(v_detour_score, 2),
        'detour_percent', ROUND(v_detour_percent, 1),
        'max_allowed_percent', v_config.max_detour_percent
      ),
      'total_score', ROUND(v_total_score, 2),
      'min_viable_score', v_config.min_viable_score
    ) AS breakdown,
    v_rejection_reason AS rejection_reason;
END;
$ LANGUAGE plpgsql;

COMMENT ON FUNCTION calculate_pool_viability_score IS 'Calculates pool viability score (0-100) with front-route consideration';

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

-- Calculate distance between two points (in kilometers)
CREATE OR REPLACE FUNCTION calculate_distance(
  lat1 DECIMAL, 
  lng1 DECIMAL,
  lat2 DECIMAL, 
  lng2 DECIMAL
)
RETURNS DECIMAL AS $
BEGIN
  RETURN ST_Distance(
    ST_SetSRID(ST_MakePoint(lng1, lat1), 4326)::geography,
    ST_SetSRID(ST_MakePoint(lng2, lat2), 4326)::geography
  ) / 1000;
END;
$ LANGUAGE plpgsql IMMUTABLE;

-- Find matching pools for a rider request (front-route only)
CREATE OR REPLACE FUNCTION find_matching_pools(
  p_pickup_lat DECIMAL,
  p_pickup_lng DECIMAL,
  p_dest_lat DECIMAL,
  p_dest_lng DECIMAL,
  p_vehicle_type VARCHAR,
  p_gender_restriction VARCHAR DEFAULT 'ANY',
  p_destination_radius_km DECIMAL DEFAULT 2,
  p_pickup_radius_km DECIMAL DEFAULT 5,
  p_config_name VARCHAR DEFAULT 'default'
)
RETURNS TABLE (
  pool_id UUID,
  creator_user_id UUID,
  driver_id UUID,
  vehicle_type VARCHAR,
  current_passengers INTEGER,
  max_passengers INTEGER,
  available_seats INTEGER,
  destination_distance_km DECIMAL,
  pickup_distance_km DECIMAL,
  pool_status VARCHAR,
  gender_restriction VARCHAR,
  estimated_departure TIMESTAMP WITH TIME ZONE,
  fare_per_person DECIMAL,
  viability_score DECIMAL
) AS $
DECLARE
  v_config RECORD;
BEGIN
  SELECT * INTO v_config
  FROM public.pool_scoring_config
  WHERE config_name = p_config_name AND is_active = TRUE
  LIMIT 1;
  
  RETURN QUERY
  SELECT
    p.id AS pool_id,
    p.creator_user_id,
    p.driver_id,
    p.vehicle_type,
    p.current_passengers,
    p.max_passengers,
    (p.max_passengers - p.current_passengers) AS available_seats,
    (ST_Distance(
      p.destination_location,
      ST_SetSRID(ST_MakePoint(p_dest_lng, p_dest_lat), 4326)::geography
    ) / 1000)::DECIMAL AS destination_distance_km,
    (ST_Distance(
      ST_SetSRID(ST_MakePoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
      p.destination_location
    ) / 1000)::DECIMAL AS pickup_distance_km,
    p.status AS pool_status,
    p.gender_restriction,
    p.estimated_departure,
    p.fare_per_person,
    p.viability_score
  FROM public.pools p
  WHERE p.deleted_at IS NULL
    AND p.status IN ('WAITING_FOR_RIDERS', 'WAITING_FOR_DRIVER', 'READY_TO_START')
    AND p.current_passengers < p.max_passengers
    AND p.vehicle_type = p_vehicle_type
    AND (p.gender_restriction = 'ANY' OR p.gender_restriction = p_gender_restriction OR p_gender_restriction = 'ANY')
    AND ST_DWithin(
      p.destination_location,
      ST_SetSRID(ST_MakePoint(p_dest_lng, p_dest_lat), 4326)::geography,
      p_destination_radius_km * 1000
    )
  ORDER BY 
    COALESCE(p.viability_score, 0) DESC,
    destination_distance_km ASC,
    p.current_passengers DESC;
END;
$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION find_matching_pools IS 'Finds available pools matching rider request with scoring';

-- Find pools for drivers (prioritizing their preferred destination)
CREATE OR REPLACE FUNCTION find_pools_for_driver(
  p_driver_id UUID,
  p_driver_current_lat DECIMAL,
  p_driver_current_lng DECIMAL,
  p_max_pickup_distance_km DECIMAL DEFAULT 5,
  p_priority_destination_weight DECIMAL DEFAULT 0.3
)
RETURNS TABLE (
  pool_id UUID,
  creator_user_id UUID,
  destination_address TEXT,
  destination_lat DECIMAL,
  destination_lng DECIMAL,
  pickup_distance_km DECIMAL,
  destination_distance_from_priority_km DECIMAL,
  current_passengers INTEGER,
  max_passengers INTEGER,
  vehicle_type VARCHAR,
  gender_restriction VARCHAR,
  pool_status VARCHAR,
  fare_per_person DECIMAL,
  estimated_departure TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE,
  is_priority_destination BOOLEAN,
  is_on_route_to_priority BOOLEAN,
  match_score DECIMAL,
  viability_score DECIMAL
) AS $
DECLARE
  v_driver_priority_lat DECIMAL;
  v_driver_priority_lng DECIMAL;
  v_driver_priority_location GEOGRAPHY;
  v_is_driver BOOLEAN;
  v_driver_current_location GEOGRAPHY;
BEGIN
  SELECT 
    is_driver, 
    driver_priority_destination_lat,
    driver_priority_destination_lng,
    driver_priority_destination_location
  INTO 
    v_is_driver, 
    v_driver_priority_lat,
    v_driver_priority_lng,
    v_driver_priority_location
  FROM public.users
  WHERE id = p_driver_id;
  
  IF NOT v_is_driver THEN
    RAISE EXCEPTION 'User % is not a driver', p_driver_id;
  END IF;
  
  v_driver_current_location := ST_SetSRID(
    ST_MakePoint(p_driver_current_lng, p_driver_current_lat), 
    4326
  )::geography;
  
  RETURN QUERY
  WITH pool_metrics AS (
    SELECT
      p.id AS pool_id,
      p.creator_user_id,
      p.destination_address,
      p.destination_lat,
      p.destination_lng,
      p.destination_location,
      p.current_passengers,
      p.max_passengers,
      p.vehicle_type,
      p.gender_restriction,
      p.status AS pool_status,
      p.fare_per_person,
      p.estimated_departure,
      p.created_at,
      p.viability_score,
      (ST_Distance(
        v_driver_current_location,
        (
          SELECT r.pickup_location
          FROM public.rides r
          INNER JOIN public.pool_members pm ON pm.ride_id = r.id
          WHERE pm.pool_id = p.id AND pm.is_front_route_passenger = TRUE
          ORDER BY pm.joined_at ASC
          LIMIT 1
        )
      ) / 1000)::DECIMAL AS pickup_distance_km,
      CASE 
        WHEN v_driver_priority_location IS NOT NULL THEN
          (ST_Distance(p.destination_location, v_driver_priority_location) / 1000)::DECIMAL
        ELSE NULL
      END AS destination_distance_from_priority_km,
      CASE 
        WHEN v_driver_priority_location IS NOT NULL 
          AND ST_DWithin(p.destination_location, v_driver_priority_location, 2000)
        THEN TRUE
        ELSE FALSE
      END AS is_priority_destination,
      CASE 
        WHEN v_driver_priority_location IS NOT NULL THEN
          (
            ST_Distance(v_driver_current_location, p.destination_location) +
            ST_Distance(p.destination_location, v_driver_priority_location)
          ) < (
            ST_Distance(v_driver_current_location, v_driver_priority_location) * 1.3
          )
        ELSE FALSE
      END AS is_on_route_to_priority
    FROM public.pools p
    WHERE p.deleted_at IS NULL
      AND p.status IN ('WAITING_FOR_DRIVER', 'READY_TO_START')
      AND p.driver_id IS NULL
      AND p.current_passengers >= p.min_passengers_to_start
      AND EXISTS (
        SELECT 1
        FROM public.rides r
        INNER JOIN public.pool_members pm ON pm.ride_id = r.id
        WHERE pm.pool_id = p.id
        AND pm.is_front_route_passenger = TRUE
        AND ST_DWithin(v_driver_current_location, r.pickup_location, p_max_pickup_distance_km * 1000)
      )
  )
  SELECT
    pm.pool_id,
    pm.creator_user_id,
    pm.destination_address,
    pm.destination_lat,
    pm.destination_lng,
    pm.pickup_distance_km,
    pm.destination_distance_from_priority_km,
    pm.current_passengers,
    pm.max_passengers,
    pm.vehicle_type,
    pm.gender_restriction,
    pm.pool_status,
    pm.fare_per_person,
    pm.estimated_departure,
    pm.created_at,
    pm.is_priority_destination,
    pm.is_on_route_to_priority,
    (
      GREATEST(0, 40 - (pm.pickup_distance_km * 8)) +
      CASE 
        WHEN pm.is_priority_destination THEN 30
        WHEN pm.is_on_route_to_priority THEN 20
        WHEN pm.destination_distance_from_priority_km IS NOT NULL THEN
          GREATEST(0, 10 - pm.destination_distance_from_priority_km)
        ELSE 0
      END +
      (pm.current_passengers::DECIMAL / pm.max_passengers * 15) +
      LEAST(15, EXTRACT(EPOCH FROM (NOW() - pm.created_at)) / 60)
    )::DECIMAL AS match_score,
    pm.viability_score
  FROM pool_metrics pm
  ORDER BY 
    match_score DESC,
    pm.viability_score DESC NULLS LAST,
    pm.pickup_distance_km ASC,
    pm.current_passengers DESC;
END;
$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION find_pools_for_driver IS 'Finds available pools for driver (front-route passengers only)';

-- Update driver location helper function
CREATE OR REPLACE FUNCTION update_driver_location(
  p_driver_id UUID,
  p_vehicle_id UUID,
  p_current_lat DECIMAL,
  p_current_lng DECIMAL,
  p_heading DECIMAL DEFAULT NULL,
  p_speed_kmh DECIMAL DEFAULT NULL,
  p_accuracy_meters INTEGER DEFAULT NULL,
  p_pool_id UUID DEFAULT NULL
)
RETURNS UUID AS $
DECLARE
  v_location_id UUID;
  v_is_driver BOOLEAN;
BEGIN
  SELECT is_driver INTO v_is_driver
  FROM public.users
  WHERE id = p_driver_id;
  
  IF NOT v_is_driver THEN
    RAISE EXCEPTION 'User % is not a driver', p_driver_id;
  END IF;
  
  UPDATE public.vehicle_locations
  SET is_active = FALSE
  WHERE vehicle_id = p_vehicle_id AND is_active = TRUE;
  
  INSERT INTO public.vehicle_locations (
    vehicle_id, driver_id, pool_id,
    current_lat, current_lng,
    heading, speed_kmh, accuracy_meters,
    is_active, is_available
  ) VALUES (
    p_vehicle_id, p_driver_id, p_pool_id,
    p_current_lat, p_current_lng,
    p_heading, p_speed_kmh, p_accuracy_meters,
    TRUE, p_pool_id IS NULL
  )
  RETURNING id INTO v_location_id;
  
  RETURN v_location_id;
END;
$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION update_driver_location IS 'Updates driver vehicle location';

-- Get user statistics
CREATE OR REPLACE FUNCTION get_user_stats(user_uuid UUID)
RETURNS TABLE (
  total_rides_count INTEGER,
  completed_rides INTEGER,
  cancelled_rides INTEGER,
  average_rating DECIMAL,
  total_ratings_count INTEGER,
  total_spent DECIMAL
) AS $
BEGIN
  RETURN QUERY
  SELECT
    u.total_rides AS total_rides_count,
    (SELECT COUNT(*)::INTEGER FROM public.rides WHERE user_id = user_uuid AND status = 'COMPLETED') AS completed_rides,
    (SELECT COUNT(*)::INTEGER FROM public.rides WHERE user_id = user_uuid AND status = 'CANCELLED') AS cancelled_rides,
    u.average_rating,
    u.total_ratings AS total_ratings_count,
    COALESCE((SELECT SUM(amount) FROM public.payments WHERE user_id = user_uuid AND status = 'COMPLETED'), 0) AS total_spent
  FROM public.users u
  WHERE u.id = user_uuid;
END;
$ LANGUAGE plpgsql SECURITY DEFINER;

-- Check if two users are priyo sathi
CREATE OR REPLACE FUNCTION are_priyo_sathi(user1_uuid UUID, user2_uuid UUID)
RETURNS BOOLEAN AS $
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.priyo_sathi
    WHERE (user_id = user1_uuid AND companion_id = user2_uuid AND status = 'ACCEPTED')
    OR (user_id = user2_uuid AND companion_id = user1_uuid AND status = 'ACCEPTED')
  );
END;
$ LANGUAGE plpgsql SECURITY DEFINER;

-- Check if new rider can join existing pool
CREATE OR REPLACE FUNCTION can_join_pool(
  p_pool_id UUID,
  p_new_ride_id UUID,
  p_config_name VARCHAR DEFAULT 'default'
)
RETURNS TABLE (
  can_join BOOLEAN,
  viability_score DECIMAL,
  score_breakdown JSONB,
  rejection_reason TEXT
) AS $
DECLARE
  v_existing_ride_id UUID;
  v_score_result RECORD;
  v_config RECORD;
BEGIN
  -- Get config
  SELECT * INTO v_config
  FROM public.pool_scoring_config
  WHERE config_name = p_config_name AND is_active = TRUE
  LIMIT 1;
  
  -- Get existing front-route ride from pool
  SELECT ride_id INTO v_existing_ride_id
  FROM public.pool_members
  WHERE pool_id = p_pool_id 
    AND left_at IS NULL
    AND (NOT v_config.front_route_only OR is_front_route_passenger = TRUE)
  LIMIT 1;
  
  IF v_existing_ride_id IS NULL THEN
    RETURN QUERY SELECT TRUE, 100.0, '{}'::JSONB, 'First member - auto-approved'::TEXT;
    RETURN;
  END IF;
  
  SELECT * INTO v_score_result
  FROM calculate_pool_viability_score(v_existing_ride_id, p_new_ride_id, p_config_name);
  
  RETURN QUERY SELECT
    v_score_result.is_viable,
    v_score_result.total_score,
    v_score_result.breakdown,
    v_score_result.rejection_reason;
END;
$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- VIEWS FOR COMMON QUERIES
-- ============================================

CREATE OR REPLACE VIEW v_active_pools_detail AS
SELECT
  p.id AS pool_id,
  p.creator_user_id,
  p.driver_id,
  p.vehicle_id,
  p.status,
  p.destination_lat,
  p.destination_lng,
  p.destination_address,
  p.vehicle_type,
  p.gender_restriction,
  p.current_passengers,
  p.max_passengers,
  (p.max_passengers - p.current_passengers) AS available_seats,
  p.fare_per_person,
  p.viability_score,
  p.estimated_departure,
  p.estimated_arrival,
  p.hexagon_region_id,
  p.created_at,
  u_creator.gender AS creator_gender,
  u_driver.average_rating AS driver_rating,
  u_driver.total_rides AS driver_total_rides,
  v.vehicle_number,
  v.model AS vehicle_model,
  v.color AS vehicle_color
FROM public.pools p
LEFT JOIN public.users u_creator ON u_creator.id = p.creator_user_id
LEFT JOIN public.users u_driver ON u_driver.id = p.driver_id
LEFT JOIN public.vehicles v ON v.id = p.vehicle_id
WHERE p.deleted_at IS NULL
  AND p.status IN ('WAITING_FOR_RIDERS', 'WAITING_FOR_DRIVER', 'READY_TO_START', 'STARTED');

CREATE OR REPLACE VIEW v_active_pools_with_vehicles AS
SELECT
  p.id AS pool_id,
  p.creator_user_id,
  p.driver_id,
  p.vehicle_id,
  p.status,
  p.destination_lat,
  p.destination_lng,
  p.destination_address,
  p.vehicle_type,
  p.gender_restriction,
  p.current_passengers,
  p.max_passengers,
  (p.max_passengers - p.current_passengers) AS available_seats,
  p.fare_per_person,
  p.viability_score,
  p.estimated_departure,
  p.estimated_arrival,
  p.route_polyline,
  p.created_at,
  u_driver.average_rating AS driver_rating,
  u_driver.total_rides AS driver_total_rides,
  v.vehicle_number,
  v.model AS vehicle_model,
  v.color AS vehicle_color,
  vl.current_lat AS vehicle_current_lat,
  vl.current_lng AS vehicle_current_lng,
  vl.heading AS vehicle_heading,
  vl.speed_kmh AS vehicle_speed,
  vl.recorded_at AS location_updated_at
FROM public.pools p
LEFT JOIN public.users u_driver ON u_driver.id = p.driver_id
LEFT JOIN public.vehicles v ON v.id = p.vehicle_id
LEFT JOIN LATERAL (
  SELECT DISTINCT ON (vehicle_id)
    vehicle_id, current_lat, current_lng,
    heading, speed_kmh, recorded_at
  FROM public.vehicle_locations
  WHERE vehicle_id = p.vehicle_id AND is_active = TRUE
  ORDER BY vehicle_id, recorded_at DESC
) vl ON vl.vehicle_id = p.vehicle_id
WHERE p.deleted_at IS NULL
  AND p.status IN ('WAITING_FOR_RIDERS', 'WAITING_FOR_DRIVER', 'READY_TO_START', 'STARTED');

COMMENT ON VIEW v_active_pools_detail IS 'Active pools with driver and member information';
COMMENT ON VIEW v_active_pools_with_vehicles IS 'Active pools with real-time vehicle locations';

-- ============================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================

ALTER TABLE public.app_metadata ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vehicle_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pool_scoring_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pools ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pool_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pool_driver_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.priyo_sathi ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- Metadata policies
CREATE POLICY "Anyone can view public metadata"
  ON public.app_metadata FOR SELECT
  USING (is_public = TRUE);

CREATE POLICY "Admins can manage metadata"
  ON public.app_metadata FOR ALL
  USING (EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND is_verified = TRUE));

-- Users policies
CREATE POLICY "Users can view their own profile"
  ON public.users FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Users can view other users' public info"
  ON public.users FOR SELECT
  USING (deleted_at IS NULL);

CREATE POLICY "Users can update their own profile"
  ON public.users FOR UPDATE
  USING (auth.uid() = id);

-- Vehicles policies
CREATE POLICY "Anyone can view active vehicles"
  ON public.vehicles FOR SELECT
  USING (is_active = TRUE AND deleted_at IS NULL);

CREATE POLICY "Drivers can manage their own vehicles"
  ON public.vehicles FOR ALL
  USING (auth.uid() = driver_id);

-- Vehicle locations policies
CREATE POLICY "Drivers can manage their own vehicle location"
  ON public.vehicle_locations FOR ALL
  USING (auth.uid() = driver_id);

CREATE POLICY "Pool members can view vehicle location for their pool"
  ON public.vehicle_locations FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.pool_members
      WHERE pool_members.pool_id = vehicle_locations.pool_id
      AND pool_members.user_id = auth.uid()
    )
  );

-- Scoring config policies
CREATE POLICY "Anyone can view active scoring configs"
  ON public.pool_scoring_config FOR SELECT
  USING (is_active = TRUE);

-- Pools policies
CREATE POLICY "Anyone can view available pools"
  ON public.pools FOR SELECT
  USING (
    status IN ('WAITING_FOR_RIDERS', 'WAITING_FOR_DRIVER', 'READY_TO_START', 'STARTED') 
    AND deleted_at IS NULL
  );

CREATE POLICY "Users can create pools"
  ON public.pools FOR INSERT
  WITH CHECK (auth.uid() = creator_user_id);

CREATE POLICY "Pool creators and drivers can update pools"
  ON public.pools FOR UPDATE
  USING (auth.uid() = creator_user_id OR auth.uid() = driver_id);

-- Rides policies
CREATE POLICY "Users can view their own rides"
  ON public.rides FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create rides"
  ON public.rides FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own rides"
  ON public.rides FOR UPDATE
  USING (auth.uid() = user_id);

-- Pool members policies
CREATE POLICY "Pool members can view other members"
  ON public.pool_members FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.pool_members pm
      WHERE pm.pool_id = pool_members.pool_id AND pm.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can join pools"
  ON public.pool_members FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Driver assignments policies
CREATE POLICY "Drivers can view assignments"
  ON public.pool_driver_assignments FOR SELECT
  USING (auth.uid() = driver_id);

CREATE POLICY "Drivers can create assignments"
  ON public.pool_driver_assignments FOR INSERT
  WITH CHECK (auth.uid() = driver_id);

-- Priyo Sathi policies
CREATE POLICY "Users can view their companions"
  ON public.priyo_sathi FOR SELECT
  USING (auth.uid() = user_id OR auth.uid() = companion_id);

CREATE POLICY "Users can manage their companions"
  ON public.priyo_sathi FOR ALL
  USING (auth.uid() = user_id OR auth.uid() = companion_id);

-- Payments policies
CREATE POLICY "Users can view their own payments"
  ON public.payments FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create payments for their rides"
  ON public.payments FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Ratings policies
CREATE POLICY "Anyone can view ratings"
  ON public.ratings FOR SELECT
  USING (true);

CREATE POLICY "Users can create ratings for their rides"
  ON public.ratings FOR INSERT
  WITH CHECK (auth.uid() = rater_id);

-- Notifications policies
CREATE POLICY "Users can view their own notifications"
  ON public.notifications FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can update their own notifications"
  ON public.notifications FOR UPDATE
  USING (auth.uid() = user_id);

-- ============================================
-- SCHEMA COMPLETE
-- ============================================