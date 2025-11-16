-- ============================================
-- supabase/migrations/002_rider_centric_pooling_complete.sql
-- Complete Schema for Rider-Centric Pooling System with Vehicle Tracking
-- ============================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" CASCADE;
CREATE EXTENSION IF NOT EXISTS postgis CASCADE;

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
COMMENT ON COLUMN public.users.driver_priority_destination_lat IS 'Driver preferred destination latitude for pool prioritization';

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
CREATE INDEX idx_pools_created_at ON public.pools(created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_pools_deleted_at ON public.pools(deleted_at);

COMMENT ON TABLE public.pools IS 'Rider-centric rideshare pools - each rider creates/joins a pool';
COMMENT ON COLUMN public.pools.creator_user_id IS 'The rider who initiated this pool';
COMMENT ON COLUMN public.pools.driver_id IS 'Driver assigned to this pool (nullable until driver selects)';
COMMENT ON COLUMN public.pools.status IS 'Pool lifecycle: WAITING_FOR_RIDERS → WAITING_FOR_DRIVER → READY_TO_START → STARTED → COMPLETED';
COMMENT ON COLUMN public.pools.min_passengers_to_start IS 'Minimum riders needed before pool can start (default 2)';
COMMENT ON COLUMN public.pools.gender_restriction IS 'Gender restriction for entire pool (FEMALE_ONLY or ANY)';
COMMENT ON COLUMN public.pools.hexagon_region_id IS 'Hexagonal region ID for spatial optimization and pool merging';
COMMENT ON COLUMN public.pools.route_polyline IS 'Encoded polyline for route matching and dynamic pooling';

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
COMMENT ON COLUMN public.vehicle_locations.is_available IS 'Whether driver is available to accept new pool assignments';



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
CREATE INDEX idx_rides_created_at ON public.rides(created_at DESC);
CREATE INDEX idx_rides_pool_status ON public.rides(pool_id, status) WHERE pool_id IS NOT NULL;

COMMENT ON TABLE public.rides IS 'Individual ride requests from passengers';
COMMENT ON COLUMN public.rides.preferred_gender_restriction IS 'Individual rider gender preference';
COMMENT ON COLUMN public.rides.walking_distance_meters IS 'Walking distance for dynamic pool joining';

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
  UNIQUE(pool_id, user_id),
  UNIQUE(ride_id)
);

CREATE INDEX idx_pool_members_pool_id ON public.pool_members(pool_id);
CREATE INDEX idx_pool_members_user_id ON public.pool_members(user_id);
CREATE INDEX idx_pool_members_ride_id ON public.pool_members(ride_id);
CREATE INDEX idx_pool_members_pool_active ON public.pool_members(pool_id) WHERE left_at IS NULL;

COMMENT ON TABLE public.pool_members IS 'Junction table tracking pool membership with join types';
COMMENT ON COLUMN public.pool_members.join_type IS 'INITIAL (joined during pool formation) or DYNAMIC (joined during trip)';

-- ============================================
-- POOL_DRIVER_ASSIGNMENTS TABLE (Driver Selection History)
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

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_vehicles_updated_at BEFORE UPDATE ON public.vehicles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_vehicle_locations_updated_at BEFORE UPDATE ON public.vehicle_locations
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
-- BUSINESS LOGIC TRIGGERS
-- ============================================

-- Sync pool passenger count and status
CREATE OR REPLACE FUNCTION sync_pool_status()
RETURNS TRIGGER AS $$
DECLARE
  v_pool_id UUID;
  v_count INTEGER;
  v_max_passengers INTEGER;
  v_min_passengers INTEGER;
  v_has_driver BOOLEAN;
  v_current_status VARCHAR;
BEGIN
  v_pool_id = COALESCE(NEW.pool_id, OLD.pool_id);
  
  -- Get pool info
  SELECT 
    max_passengers, 
    min_passengers_to_start,
    (driver_id IS NOT NULL),
    status
  INTO v_max_passengers, v_min_passengers, v_has_driver, v_current_status
  FROM public.pools
  WHERE id = v_pool_id;
  
  -- Count current active members
  SELECT COUNT(*) INTO v_count
  FROM public.pool_members
  WHERE pool_id = v_pool_id AND left_at IS NULL;
  
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
$$ LANGUAGE plpgsql;

CREATE TRIGGER sync_pool_status_on_member_change
AFTER INSERT OR UPDATE OR DELETE ON public.pool_members
FOR EACH ROW
EXECUTE FUNCTION sync_pool_status();

-- Update pool status when driver is assigned


CREATE OR REPLACE FUNCTION sync_pool_status_internal(p_pool_id UUID)
RETURNS VOID AS $$
DECLARE
  v_count INTEGER;
  v_max_passengers INTEGER;
  v_min_passengers INTEGER;
  v_has_driver BOOLEAN;
BEGIN
  SELECT 
    max_passengers, 
    min_passengers_to_start,
    (driver_id IS NOT NULL)
  INTO v_max_passengers, v_min_passengers, v_has_driver
  FROM public.pools
  WHERE id = p_pool_id;
  
  SELECT COUNT(*) INTO v_count
  FROM public.pool_members
  WHERE pool_id = p_pool_id AND left_at IS NULL;
  
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
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sync_pool_status_on_driver_change()
RETURNS TRIGGER AS $$
BEGIN
  PERFORM sync_pool_status_internal(NEW.id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER sync_pool_status_on_driver_assignment
AFTER UPDATE OF driver_id ON public.pools
FOR EACH ROW
WHEN (OLD.driver_id IS DISTINCT FROM NEW.driver_id)
EXECUTE FUNCTION sync_pool_status_on_driver_change();

-- Cascade pool cancellation
CREATE OR REPLACE FUNCTION cascade_pool_cancellation()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

CREATE TRIGGER cascade_pool_cancel
AFTER UPDATE OF status ON public.pools
FOR EACH ROW
WHEN (NEW.status = 'CANCELLED' AND OLD.status != 'CANCELLED')
EXECUTE FUNCTION cascade_pool_cancellation();

-- Update user ratings
CREATE OR REPLACE FUNCTION update_user_rating()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_user_rating_trigger
AFTER INSERT ON public.ratings
FOR EACH ROW
EXECUTE FUNCTION update_user_rating();

-- Update user ride count
CREATE OR REPLACE FUNCTION update_user_ride_count()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'COMPLETED' AND OLD.status != 'COMPLETED' THEN
    UPDATE public.users
    SET total_rides = total_rides + 1
    WHERE id = NEW.user_id;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_user_ride_count_trigger
AFTER UPDATE OF status ON public.rides
FOR EACH ROW
WHEN (NEW.status = 'COMPLETED' AND OLD.status != 'COMPLETED')
EXECUTE FUNCTION update_user_ride_count();

-- ============================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vehicle_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pools ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pool_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pool_driver_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.priyo_sathi ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

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
CREATE POLICY "Drivers can view and update their own vehicle location"
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

CREATE POLICY "Anyone can view available vehicle locations"
  ON public.vehicle_locations FOR SELECT
  USING (is_available = TRUE AND is_active = TRUE);

-- Pools policies
CREATE POLICY "Anyone can view available pools"
  ON public.pools FOR SELECT
  USING (
    status IN ('WAITING_FOR_RIDERS', 'WAITING_FOR_DRIVER', 'READY_TO_START', 'STARTED') 
    AND deleted_at IS NULL
  );

CREATE POLICY "Pool members can view their pools"
  ON public.pools FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.pool_members
      WHERE pool_members.pool_id = pools.id
      AND pool_members.user_id = auth.uid()
    )
  );

CREATE POLICY "Drivers can view pools they're assigned to"
  ON public.pools FOR SELECT
  USING (auth.uid() = driver_id);

CREATE POLICY "Users can create pools when creating rides"
  ON public.pools FOR INSERT
  WITH CHECK (auth.uid() = creator_user_id);

CREATE POLICY "Pool creators and drivers can update pools"
  ON public.pools FOR UPDATE
  USING (auth.uid() = creator_user_id OR auth.uid() = driver_id);

CREATE POLICY "Pool creators can delete their pools"
  ON public.pools FOR DELETE
  USING (auth.uid() = creator_user_id);

-- Rides policies
CREATE POLICY "Users can view their own rides"
  ON public.rides FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Drivers can view rides in their assigned pools"
  ON public.rides FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.pools
      WHERE pools.id = rides.pool_id
      AND pools.driver_id = auth.uid()
    )
  );

CREATE POLICY "Pool members can view other rides in their pool"
  ON public.rides FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.pool_members pm1
      INNER JOIN public.pool_members pm2 ON pm1.pool_id = pm2.pool_id
      WHERE pm1.user_id = auth.uid()
      AND pm2.ride_id = rides.id
    )
  );

CREATE POLICY "Users can create rides"
  ON public.rides FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own rides"
  ON public.rides FOR UPDATE
  USING (auth.uid() = user_id);

-- Pool members policies
CREATE POLICY "Pool members can view other members in same pool"
  ON public.pool_members FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.pool_members pm
      WHERE pm.pool_id = pool_members.pool_id
      AND pm.user_id = auth.uid()
    )
    OR
    EXISTS (
      SELECT 1 FROM public.pools
      WHERE pools.id = pool_members.pool_id
      AND pools.driver_id = auth.uid()
    )
  );

CREATE POLICY "Users can join pools"
  ON public.pool_members FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Pool driver assignments policies
CREATE POLICY "Drivers can view assignments for their pools"
  ON public.pool_driver_assignments FOR SELECT
  USING (auth.uid() = driver_id);

CREATE POLICY "Pool members can view driver assignments for their pools"
  ON public.pool_driver_assignments FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.pool_members
      WHERE pool_members.pool_id = pool_driver_assignments.pool_id
      AND pool_members.user_id = auth.uid()
    )
  );

CREATE POLICY "Drivers can create assignments"
  ON public.pool_driver_assignments FOR INSERT
  WITH CHECK (
    auth.uid() = driver_id
    AND EXISTS (
      SELECT 1 FROM public.users
      WHERE id = auth.uid() AND is_driver = TRUE
    )
  );

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
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1 FROM public.rides
      WHERE rides.id = payments.ride_id
      AND rides.user_id = auth.uid()
    )
  );

-- Ratings policies
CREATE POLICY "Anyone can view ratings"
  ON public.ratings FOR SELECT
  USING (true);

CREATE POLICY "Users can create ratings for their rides"
  ON public.ratings FOR INSERT
  WITH CHECK (
    auth.uid() = rater_id
    AND EXISTS (
      SELECT 1 FROM public.rides
      WHERE rides.id = ratings.ride_id
      AND (rides.user_id = auth.uid() OR EXISTS (
        SELECT 1 FROM public.pools
        WHERE pools.id = rides.pool_id
        AND pools.driver_id = auth.uid()
      ))
    )
  );

-- Notifications policies
CREATE POLICY "Users can view their own notifications"
  ON public.notifications FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can update their own notifications"
  ON public.notifications FOR UPDATE
  USING (auth.uid() = user_id);

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
RETURNS DECIMAL AS $$
BEGIN
  RETURN ST_Distance(
    ST_SetSRID(ST_MakePoint(lng1, lat1), 4326)::geography,
    ST_SetSRID(ST_MakePoint(lng2, lat2), 4326)::geography
  ) / 1000;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Find matching pools for a rider request
CREATE OR REPLACE FUNCTION find_matching_pools(
  p_pickup_lat DECIMAL,
  p_pickup_lng DECIMAL,
  p_dest_lat DECIMAL,
  p_dest_lng DECIMAL,
  p_vehicle_type VARCHAR,
  p_gender_restriction VARCHAR DEFAULT 'ANY',
  p_destination_radius_km DECIMAL DEFAULT 2,
  p_pickup_radius_km DECIMAL DEFAULT 5
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
  fare_per_person DECIMAL
) AS $
BEGIN
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
    p.fare_per_person
  FROM public.pools p
  WHERE p.deleted_at IS NULL
    AND p.status IN ('WAITING_FOR_RIDERS', 'WAITING_FOR_DRIVER', 'READY_TO_START')
    AND p.current_passengers < p.max_passengers
    AND p.vehicle_type = p_vehicle_type
    -- Match gender restrictions
    AND (
      p.gender_restriction = 'ANY' 
      OR p.gender_restriction = p_gender_restriction
      OR p_gender_restriction = 'ANY'
    )
    -- Destination must be within radius
    AND ST_DWithin(
      p.destination_location,
      ST_SetSRID(ST_MakePoint(p_dest_lng, p_dest_lat), 4326)::geography,
      p_destination_radius_km * 1000
    )
  ORDER BY destination_distance_km, p.current_passengers DESC;
END;
$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION find_matching_pools IS 'Finds available pools matching rider request criteria';

-- Find pools for dynamic matching (while trip is in progress)
CREATE OR REPLACE FUNCTION find_dynamic_matching_pools(
  p_pickup_lat DECIMAL,
  p_pickup_lng DECIMAL,
  p_dest_lat DECIMAL,
  p_dest_lng DECIMAL,
  p_vehicle_type VARCHAR,
  p_gender_restriction VARCHAR DEFAULT 'ANY',
  p_route_radius_m INTEGER DEFAULT 500,
  p_max_walking_distance_m INTEGER DEFAULT 300,
  p_destination_radius_km DECIMAL DEFAULT 2
)
RETURNS TABLE (
  pool_id UUID,
  driver_id UUID,
  vehicle_id UUID,
  vehicle_type VARCHAR,
  current_passengers INTEGER,
  available_seats INTEGER,
  vehicle_current_lat DECIMAL,
  vehicle_current_lng DECIMAL,
  distance_to_pickup_m INTEGER,
  distance_along_route_m INTEGER,
  destination_distance_km DECIMAL,
  walking_distance_meters INTEGER,
  pool_status VARCHAR,
  estimated_arrival TIMESTAMP WITH TIME ZONE,
  fare_per_person DECIMAL
) AS $
BEGIN
  RETURN QUERY
  WITH active_vehicles AS (
    SELECT DISTINCT ON (vl.vehicle_id)
      vl.vehicle_id,
      vl.driver_id,
      vl.pool_id,
      vl.current_lat,
      vl.current_lng,
      vl.current_location,
      vl.heading,
      vl.speed_kmh
    FROM public.vehicle_locations vl
    WHERE vl.is_active = TRUE
    ORDER BY vl.vehicle_id, vl.recorded_at DESC
  ),
  route_analysis AS (
    SELECT
      p.id AS pool_id,
      p.driver_id,
      p.vehicle_id,
      p.vehicle_type,
      p.current_passengers,
      p.max_passengers,
      p.status,
      p.estimated_arrival,
      p.fare_per_person,
      p.destination_location,
      p.route_polyline,
      av.current_lat,
      av.current_lng,
      av.current_location,
      ST_Distance(
        ST_SetSRID(ST_MakePoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
        av.current_location
      ) AS distance_to_pickup_m,
      ST_Distance(
        ST_SetSRID(ST_MakePoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
        p.destination_location
      ) AS pickup_to_dest_m,
      ST_Distance(
        p.destination_location,
        ST_SetSRID(ST_MakePoint(p_dest_lng, p_dest_lat), 4326)::geography
      ) AS destination_distance_m,
      CASE 
        WHEN p.route_polyline IS NOT NULL THEN
          ST_Distance(
            ST_SetSRID(ST_MakePoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
            ST_GeomFromText(p.route_polyline, 4326)::geography
          )
        ELSE NULL
      END AS distance_from_route_m
    FROM public.pools p
    INNER JOIN active_vehicles av ON av.pool_id = p.id
    WHERE p.deleted_at IS NULL
      AND p.status = 'STARTED'
      AND p.current_passengers < p.max_passengers
      AND p.vehicle_type = p_vehicle_type
      AND (p.gender_restriction = 'ANY' OR p.gender_restriction = p_gender_restriction)
  )
  SELECT
    ra.pool_id,
    ra.driver_id,
    ra.vehicle_id,
    ra.vehicle_type,
    ra.current_passengers,
    (ra.max_passengers - ra.current_passengers)::INTEGER AS available_seats,
    ra.current_lat AS vehicle_current_lat,
    ra.current_lng AS vehicle_current_lng,
    ra.distance_to_pickup_m::INTEGER,
    COALESCE(ra.distance_from_route_m, ra.distance_to_pickup_m)::INTEGER AS distance_along_route_m,
    (ra.destination_distance_m / 1000)::DECIMAL AS destination_distance_km,
    LEAST(
      ra.distance_to_pickup_m,
      COALESCE(ra.distance_from_route_m, ra.distance_to_pickup_m)
    )::INTEGER AS walking_distance_meters,
    ra.status AS pool_status,
    ra.estimated_arrival,
    ra.fare_per_person
  FROM route_analysis ra
  WHERE 
    ra.destination_distance_m <= p_destination_radius_km * 1000
    AND (
      (ra.route_polyline IS NOT NULL AND ra.distance_from_route_m <= p_route_radius_m)
      OR
      (ra.route_polyline IS NULL AND ra.distance_to_pickup_m <= p_max_walking_distance_m)
    )
    AND LEAST(
      ra.distance_to_pickup_m,
      COALESCE(ra.distance_from_route_m, ra.distance_to_pickup_m)
    ) <= p_max_walking_distance_m
  ORDER BY 
    walking_distance_meters ASC,
    available_seats DESC,
    destination_distance_km ASC;
END;
$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION find_dynamic_matching_pools IS 'Finds pools for dynamic matching using real-time vehicle locations and route polylines';

-- Find available pools for drivers (prioritizing their preferred destination)
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
  match_score DECIMAL
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
      (ST_Distance(
        v_driver_current_location,
        (
          SELECT r.pickup_location
          FROM public.rides r
          INNER JOIN public.pool_members pm ON pm.ride_id = r.id
          WHERE pm.pool_id = p.id
          ORDER BY pm.joined_at ASC
          LIMIT 1
        )
      ) / 1000)::DECIMAL AS pickup_distance_km,
      CASE 
        WHEN v_driver_priority_location IS NOT NULL THEN
          (ST_Distance(
            p.destination_location,
            v_driver_priority_location
          ) / 1000)::DECIMAL
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
        AND ST_DWithin(
          v_driver_current_location,
          r.pickup_location,
          p_max_pickup_distance_km * 1000
        )
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
    )::DECIMAL AS match_score
  FROM pool_metrics pm
  ORDER BY 
    match_score DESC,
    pm.pickup_distance_km ASC,
    pm.current_passengers DESC;
END;
$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION find_pools_for_driver IS 'Finds available pools for driver considering current location and priority destination';

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
  WHERE vehicle_id = p_vehicle_id
    AND is_active = TRUE;
  
  INSERT INTO public.vehicle_locations (
    vehicle_id,
    driver_id,
    pool_id,
    current_lat,
    current_lng,
    heading,
    speed_kmh,
    accuracy_meters,
    is_active,
    is_available
  ) VALUES (
    p_vehicle_id,
    p_driver_id,
    p_pool_id,
    p_current_lat,
    p_current_lng,
    p_heading,
    p_speed_kmh,
    p_accuracy_meters,
    TRUE,
    p_pool_id IS NULL
  )
  RETURNING id INTO v_location_id;
  
  RETURN v_location_id;
END;
$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION update_driver_location IS 'Updates driver vehicle location and manages location history';

-- Find nearest available drivers
CREATE OR REPLACE FUNCTION find_nearest_available_drivers(
  p_pickup_lat DECIMAL,
  p_pickup_lng DECIMAL,
  p_vehicle_type VARCHAR DEFAULT NULL,
  p_max_distance_km DECIMAL DEFAULT 10,
  p_limit INTEGER DEFAULT 10
)
RETURNS TABLE (
  driver_id UUID,
  vehicle_id UUID,
  vehicle_type VARCHAR,
  vehicle_number VARCHAR,
  distance_km DECIMAL,
  current_lat DECIMAL,
  current_lng DECIMAL,
  heading DECIMAL,
  driver_rating DECIMAL,
  driver_total_rides INTEGER,
  location_updated_at TIMESTAMP WITH TIME ZONE
) AS $
BEGIN
  RETURN QUERY
  SELECT DISTINCT ON (vl.driver_id)
    vl.driver_id,
    vl.vehicle_id,
    veh.vehicle_type,
    veh.vehicle_number,
    (ST_Distance(
      ST_SetSRID(ST_MakePoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
      vl.current_location
    ) / 1000)::DECIMAL AS distance_km,
    vl.current_lat,
    vl.current_lng,
    vl.heading,
    u.average_rating AS driver_rating,
    u.total_rides AS driver_total_rides,
    vl.recorded_at AS location_updated_at
  FROM public.vehicle_locations vl
  INNER JOIN public.vehicles veh ON veh.id = vl.vehicle_id
  INNER JOIN public.users u ON u.id = vl.driver_id
  WHERE vl.is_available = TRUE
    AND vl.is_active = TRUE
    AND veh.is_active = TRUE
    AND veh.deleted_at IS NULL
    AND u.is_driver = TRUE
    AND u.deleted_at IS NULL
    AND (p_vehicle_type IS NULL OR veh.vehicle_type = p_vehicle_type)
    AND ST_DWithin(
      ST_SetSRID(ST_MakePoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
      vl.current_location,
      p_max_distance_km * 1000
    )
  ORDER BY vl.driver_id, distance_km ASC
  LIMIT p_limit;
END;
$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION find_nearest_available_drivers IS 'Finds nearest available drivers to a pickup location';

-- Get user ride statistics
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

-- Check if two users are priyo sathi (mutual accepted)
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

COMMENT ON FUNCTION are_priyo_sathi IS 'Checks if two users have mutual priyo sathi relationship';

-- Optimize and merge pools in the same hexagon region
CREATE OR REPLACE FUNCTION optimize_pools_in_region(
  p_hexagon_region_id VARCHAR,
  p_destination_radius_km DECIMAL DEFAULT 1
)
RETURNS TABLE (
  suggested_merge_pool_id UUID,
  mergeable_pool_ids UUID[]
) AS $
BEGIN
  RETURN QUERY
  SELECT
    p1.id AS suggested_merge_pool_id,
    ARRAY_AGG(DISTINCT p2.id) AS mergeable_pool_ids
  FROM public.pools p1
  INNER JOIN public.pools p2 ON 
    p1.hexagon_region_id = p2.hexagon_region_id
    AND p1.id != p2.id
    AND p1.vehicle_type = p2.vehicle_type
    AND p1.gender_restriction = p2.gender_restriction
    AND ST_DWithin(p1.destination_location, p2.destination_location, p_destination_radius_km * 1000)
  WHERE p1.hexagon_region_id = p_hexagon_region_id
    AND p1.deleted_at IS NULL
    AND p2.deleted_at IS NULL
    AND p1.status IN ('WAITING_FOR_RIDERS', 'WAITING_FOR_DRIVER')
    AND p2.status IN ('WAITING_FOR_RIDERS', 'WAITING_FOR_DRIVER')
    AND (p1.current_passengers + p2.current_passengers) <= p1.max_passengers
  GROUP BY p1.id;
END;
$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION optimize_pools_in_region IS 'Suggests optimal pool mergers in a hexagon region';

-- ============================================
-- VIEWS FOR COMMON QUERIES
-- ============================================

-- Active pools with driver and member information
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

-- Active pools with real-time vehicle locations
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
    vehicle_id,
    current_lat,
    current_lng,
    heading,
    speed_kmh,
    recorded_at
  FROM public.vehicle_locations
  WHERE vehicle_id = p.vehicle_id
    AND is_active = TRUE
  ORDER BY vehicle_id, recorded_at DESC
) vl ON vl.vehicle_id = p.vehicle_id
WHERE p.deleted_at IS NULL
  AND p.status IN ('WAITING_FOR_RIDERS', 'WAITING_FOR_DRIVER', 'READY_TO_START', 'STARTED');

COMMENT ON VIEW v_active_pools_detail IS 'Active pools with driver and member information';
COMMENT ON VIEW v_active_pools_with_vehicles IS 'Active pools with real-time vehicle location information';

-- ============================================
-- MIGRATION COMPLETE
-- ============================================