-- ============================================
-- RIDEPOOL SCHEMA V5 - WITH H3 LOGIC
-- Zero Business Logic - Backend Does Everything
-- SUPABASE NATIVE - NO H3 EXTENSION REQUIRED
-- Backend will calculate H3 indexes using h3-js library
-- ============================================

-- Enable extensions (only what Supabase has)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================
-- DROP ALL EXISTING TABLES (CLEAN SLATE)
-- ============================================
DROP TRIGGER IF EXISTS t_rides_geo ON public.rides CASCADE;
DROP TRIGGER IF EXISTS t_pools_geo ON public.pools CASCADE;
DROP TRIGGER IF EXISTS t_vehicle_loc_geo ON public.vehicle_locations CASCADE;
DROP TRIGGER IF EXISTS t_saved_places_geo ON public.saved_places CASCADE;
DROP TRIGGER IF EXISTS t_users_geo ON public.users CASCADE;
DROP TRIGGER IF EXISTS t_rides_ts ON public.rides CASCADE;
DROP TRIGGER IF EXISTS t_pools_ts ON public.pools CASCADE;
DROP TRIGGER IF EXISTS t_vehicles_ts ON public.vehicles CASCADE;
DROP TRIGGER IF EXISTS t_saved_places_ts ON public.saved_places CASCADE;
DROP TRIGGER IF EXISTS t_wallets_ts ON public.wallets CASCADE;
DROP TRIGGER IF EXISTS t_users_ts ON public.users CASCADE;

DROP TABLE IF EXISTS public.audit_log CASCADE;
DROP TABLE IF EXISTS public.notifications CASCADE;
DROP TABLE IF EXISTS public.messages CASCADE;
DROP TABLE IF EXISTS public.conversation_participants CASCADE;
DROP TABLE IF EXISTS public.conversations CASCADE;
DROP TABLE IF EXISTS public.safety_incidents CASCADE;
DROP TABLE IF EXISTS public.ride_sharing CASCADE;
DROP TABLE IF EXISTS public.ratings CASCADE;
DROP TABLE IF EXISTS public.user_promo_usage CASCADE;
DROP TABLE IF EXISTS public.promo_codes CASCADE;
DROP TABLE IF EXISTS public.payments CASCADE;
DROP TABLE IF EXISTS public.priyo_sathi CASCADE;
DROP TABLE IF EXISTS public.pool_members CASCADE;
DROP TABLE IF EXISTS public.rides CASCADE;
DROP TABLE IF EXISTS public.pools CASCADE;
DROP TABLE IF EXISTS public.vehicle_locations CASCADE;
DROP TABLE IF EXISTS public.vehicles CASCADE;
DROP TABLE IF EXISTS public.emergency_contacts CASCADE;
DROP TABLE IF EXISTS public.saved_places CASCADE;
DROP TABLE IF EXISTS public.wallet_transactions CASCADE;
DROP TABLE IF EXISTS public.wallets CASCADE;
DROP TABLE IF EXISTS public.users CASCADE;
DROP TABLE IF EXISTS public.app_metadata CASCADE;

-- Drop views
DROP VIEW IF EXISTS v_active_pools CASCADE;

-- Drop functions
DROP FUNCTION IF EXISTS update_timestamp() CASCADE;
DROP FUNCTION IF EXISTS calc_geography() CASCADE;

-- ============================================
-- METADATA
-- ============================================
CREATE TABLE public.app_metadata (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  key VARCHAR(100) UNIQUE NOT NULL,
  value JSONB NOT NULL,
  description TEXT,
  category VARCHAR(50),
  is_public BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_app_metadata_key ON public.app_metadata(key);

-- Insert H3 configuration (backend will use h3-js to calculate)
INSERT INTO public.app_metadata (key, value, description, category, is_public) VALUES
('h3_resolution', '{"pickup": 9, "destination": 7, "driver_search": 8}', 'H3 resolution levels for different purposes', 'h3_config', TRUE),
('h3_search_ring', '{"pickup": 1, "destination": 2, "driver": 2}', 'H3 k-ring search radius', 'h3_config', TRUE);

-- ============================================
-- USERS
-- ============================================
CREATE TABLE public.users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  phone VARCHAR(20) UNIQUE,
  phone_verified BOOLEAN DEFAULT FALSE,
  gender VARCHAR(10) CHECK (gender IN ('MALE', 'FEMALE', 'OTHER')),
  gender_preference VARCHAR(20) CHECK (gender_preference IN ('FEMALE_ONLY', 'ANY')) DEFAULT 'ANY',
  is_driver BOOLEAN DEFAULT FALSE,
  
  -- Stats (updated by backend only)
  average_rating DECIMAL(3,2),
  total_ratings INTEGER DEFAULT 0,
  total_rides INTEGER DEFAULT 0,
  
  -- Driver priority destination with H3 (backend calculates)
  driver_priority_lat DECIMAL(10,8),
  driver_priority_lng DECIMAL(11,8),
  driver_priority_location GEOGRAPHY(POINT, 4326),
  driver_priority_address TEXT,
  driver_priority_h3_index VARCHAR(20),
  
  deleted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_users_phone ON public.users(phone) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_driver ON public.users(is_driver) WHERE is_driver = TRUE;
CREATE INDEX idx_users_priority_loc ON public.users USING GIST(driver_priority_location);
CREATE INDEX idx_users_priority_h3 ON public.users(driver_priority_h3_index) WHERE driver_priority_h3_index IS NOT NULL;

-- ============================================
-- WALLETS
-- ============================================
CREATE TABLE public.wallets (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  balance DECIMAL(10,2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
  currency VARCHAR(3) DEFAULT 'BDT',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.wallet_transactions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  wallet_id UUID NOT NULL REFERENCES public.wallets(id) ON DELETE CASCADE,
  type VARCHAR(20) NOT NULL CHECK (type IN ('CREDIT', 'DEBIT', 'REFUND', 'BONUS')),
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  balance_before DECIMAL(10,2) NOT NULL,
  balance_after DECIMAL(10,2) NOT NULL,
  reference_type VARCHAR(20),
  reference_id UUID,
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_wallet_txn_wallet ON public.wallet_transactions(wallet_id, created_at DESC);

-- ============================================
-- SAVED PLACES
-- ============================================
CREATE TABLE public.saved_places (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  label VARCHAR(50) NOT NULL,
  address TEXT NOT NULL,
  lat DECIMAL(10,8) NOT NULL,
  lng DECIMAL(11,8) NOT NULL,
  location GEOGRAPHY(POINT, 4326),
  h3_index VARCHAR(20),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_saved_places_user ON public.saved_places(user_id);
CREATE UNIQUE INDEX idx_saved_places_user_label ON public.saved_places(user_id, label);
CREATE INDEX idx_saved_places_h3 ON public.saved_places(h3_index);

-- ============================================
-- EMERGENCY CONTACTS
-- ============================================
CREATE TABLE public.emergency_contacts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  name VARCHAR(100) NOT NULL,
  phone VARCHAR(20) NOT NULL,
  relationship VARCHAR(50),
  is_primary BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_emergency_contacts_user ON public.emergency_contacts(user_id);

-- ============================================
-- VEHICLES
-- ============================================
CREATE TABLE public.vehicles (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  driver_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  vehicle_type VARCHAR(10) NOT NULL CHECK (vehicle_type IN ('CAR', 'CNG')),
  vehicle_number VARCHAR(20) UNIQUE NOT NULL,
  model VARCHAR(100),
  color VARCHAR(50),
  max_passengers INTEGER NOT NULL DEFAULT 4 CHECK (max_passengers > 0),
  is_active BOOLEAN DEFAULT TRUE,
  deleted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_vehicles_driver ON public.vehicles(driver_id);
CREATE INDEX idx_vehicles_active ON public.vehicles(is_active) WHERE is_active = TRUE;

-- ============================================
-- VEHICLE LOCATIONS (High Write Volume) - WITH H3
-- ============================================
CREATE TABLE public.vehicle_locations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  vehicle_id UUID NOT NULL REFERENCES public.vehicles(id) ON DELETE CASCADE,
  driver_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  pool_id UUID,
  
  lat DECIMAL(10,8) NOT NULL,
  lng DECIMAL(11,8) NOT NULL,
  location GEOGRAPHY(POINT, 4326),
  
  -- H3 indexes (backend calculates using h3-js)
  h3_index_res8 VARCHAR(20),  -- For driver search (resolution 8)
  h3_index_res9 VARCHAR(20),  -- For pickup matching (resolution 9)
  
  heading DECIMAL(5,2),
  speed_kmh DECIMAL(5,2),
  
  is_active BOOLEAN DEFAULT TRUE,
  is_available BOOLEAN DEFAULT TRUE,
  
  recorded_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_vehicle_loc_active ON public.vehicle_locations(vehicle_id, is_active) WHERE is_active = TRUE;
CREATE INDEX idx_vehicle_loc_geo ON public.vehicle_locations USING GIST(location) WHERE is_active = TRUE;
CREATE INDEX idx_vehicle_loc_time ON public.vehicle_locations USING BRIN(recorded_at);
CREATE INDEX idx_vehicle_loc_h3_res8 ON public.vehicle_locations(h3_index_res8) WHERE is_active = TRUE;
CREATE INDEX idx_vehicle_loc_h3_res9 ON public.vehicle_locations(h3_index_res9) WHERE is_active = TRUE;
CREATE INDEX idx_vehicle_loc_available ON public.vehicle_locations(is_available, h3_index_res8) WHERE is_active = TRUE;

-- ============================================
-- POOLS (Status managed by backend) - WITH H3
-- ============================================
CREATE TABLE public.pools (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  creator_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  driver_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  vehicle_id UUID REFERENCES public.vehicles(id) ON DELETE SET NULL,
  
  status VARCHAR(20) NOT NULL DEFAULT 'WAITING_FOR_RIDERS',
  
  -- Destination with H3 indexing (backend calculates)
  destination_lat DECIMAL(10,8) NOT NULL,
  destination_lng DECIMAL(11,8) NOT NULL,
  destination_location GEOGRAPHY(POINT, 4326),
  destination_address TEXT,
  destination_h3_index VARCHAR(20),  -- Resolution 7 for destination matching
  
  vehicle_type VARCHAR(10) NOT NULL,
  gender_restriction VARCHAR(20) DEFAULT 'ANY',
  
  -- Counts (backend updates these)
  current_passengers INTEGER NOT NULL DEFAULT 0,
  max_passengers INTEGER NOT NULL DEFAULT 4,
  
  -- Backend calculated fields
  viability_score DECIMAL(5,2),
  score_breakdown JSONB,
  fare_per_person DECIMAL(10,2),
  
  deleted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ
);

CREATE INDEX idx_pools_dest ON public.pools USING GIST(destination_location);
CREATE INDEX idx_pools_status ON public.pools(status) WHERE deleted_at IS NULL;
CREATE INDEX idx_pools_search ON public.pools(status, vehicle_type, gender_restriction) WHERE deleted_at IS NULL;
CREATE INDEX idx_pools_driver ON public.pools(driver_id) WHERE driver_id IS NOT NULL;
CREATE INDEX idx_pools_dest_h3 ON public.pools(destination_h3_index, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_pools_matching ON public.pools(destination_h3_index, vehicle_type, gender_restriction, status) 
  WHERE deleted_at IS NULL AND status IN ('WAITING_FOR_RIDERS', 'WAITING_FOR_DRIVER');

-- ============================================
-- RIDES - WITH H3
-- ============================================
CREATE TABLE public.rides (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  pool_id UUID REFERENCES public.pools(id) ON DELETE SET NULL,
  
  -- Pickup location with H3 (backend calculates)
  pickup_lat DECIMAL(10,8) NOT NULL,
  pickup_lng DECIMAL(11,8) NOT NULL,
  pickup_location GEOGRAPHY(POINT, 4326),
  pickup_address TEXT,
  pickup_h3_index VARCHAR(20),  -- Resolution 9 for precise pickup matching
  
  -- Dropoff location with H3 (backend calculates)
  dropoff_lat DECIMAL(10,8) NOT NULL,
  dropoff_lng DECIMAL(11,8) NOT NULL,
  dropoff_location GEOGRAPHY(POINT, 4326),
  dropoff_address TEXT,
  dropoff_h3_index VARCHAR(20),  -- Resolution 7 for destination matching
  
  vehicle_type VARCHAR(10) NOT NULL,
  gender_restriction VARCHAR(20) DEFAULT 'ANY',
  
  status VARCHAR(20) NOT NULL DEFAULT 'CREATING_POOL',
  
  fare DECIMAL(10,2),
  distance_km DECIMAL(10,2),
  
  -- Backend calculated
  is_on_front_route BOOLEAN DEFAULT TRUE,
  route_deviation_km DECIMAL(5,2),
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  cancelled_reason TEXT
);

CREATE INDEX idx_rides_user ON public.rides(user_id, created_at DESC);
CREATE INDEX idx_rides_pool ON public.rides(pool_id) WHERE pool_id IS NOT NULL;
CREATE INDEX idx_rides_pickup ON public.rides USING GIST(pickup_location);
CREATE INDEX idx_rides_dropoff ON public.rides USING GIST(dropoff_location);
CREATE INDEX idx_rides_pickup_h3 ON public.rides(pickup_h3_index, status);
CREATE INDEX idx_rides_dropoff_h3 ON public.rides(dropoff_h3_index, status);
CREATE INDEX idx_rides_matching ON public.rides(dropoff_h3_index, vehicle_type, gender_restriction, status)
  WHERE status = 'CREATING_POOL';

-- ============================================
-- POOL MEMBERS
-- ============================================
CREATE TABLE public.pool_members (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  pool_id UUID NOT NULL REFERENCES public.pools(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  ride_id UUID NOT NULL REFERENCES public.rides(id) ON DELETE CASCADE,
  
  join_type VARCHAR(20) DEFAULT 'INITIAL',
  join_score DECIMAL(5,2),
  is_front_route BOOLEAN DEFAULT TRUE,
  
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  left_at TIMESTAMPTZ,
  
  UNIQUE(pool_id, user_id),
  UNIQUE(ride_id)
);

CREATE INDEX idx_pool_members_pool ON public.pool_members(pool_id) WHERE left_at IS NULL;
CREATE INDEX idx_pool_members_user ON public.pool_members(user_id);

-- ============================================
-- PRIYO SATHI
-- ============================================
CREATE TABLE public.priyo_sathi (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  companion_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, companion_id),
  CHECK (user_id != companion_id)
);

CREATE INDEX idx_priyo_sathi_user ON public.priyo_sathi(user_id, status);

-- ============================================
-- PAYMENTS (Idempotency built-in)
-- ============================================
CREATE TABLE public.payments (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ride_id UUID NOT NULL REFERENCES public.rides(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  
  amount DECIMAL(10,2) NOT NULL CHECK (amount >= 0),
  payment_method VARCHAR(20) NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
  
  transaction_id VARCHAR(100),
  idempotency_key VARCHAR(100),
  
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_payments_ride ON public.payments(ride_id);
CREATE INDEX idx_payments_user ON public.payments(user_id, created_at DESC);
CREATE UNIQUE INDEX idx_payments_idempotency ON public.payments(idempotency_key) 
  WHERE status = 'COMPLETED' AND idempotency_key IS NOT NULL;

-- ============================================
-- PROMO CODES
-- ============================================
CREATE TABLE public.promo_codes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  code VARCHAR(50) UNIQUE NOT NULL,
  description TEXT,
  discount_type VARCHAR(20) NOT NULL,
  discount_value DECIMAL(10,2) NOT NULL,
  max_discount_amount DECIMAL(10,2),
  min_ride_amount DECIMAL(10,2),
  usage_limit INTEGER,
  usage_count INTEGER DEFAULT 0,
  valid_from TIMESTAMPTZ,
  valid_until TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.user_promo_usage (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  promo_code_id UUID NOT NULL REFERENCES public.promo_codes(id) ON DELETE CASCADE,
  ride_id UUID REFERENCES public.rides(id),
  discount_amount DECIMAL(10,2),
  used_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_user_promo_user ON public.user_promo_usage(user_id);

-- ============================================
-- RATINGS
-- ============================================
CREATE TABLE public.ratings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ride_id UUID NOT NULL REFERENCES public.rides(id) ON DELETE CASCADE,
  rater_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  rated_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment TEXT,
  tags TEXT[],
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(ride_id, rater_id, rated_id)
);

CREATE INDEX idx_ratings_rated ON public.ratings(rated_id);

-- ============================================
-- SAFETY
-- ============================================
CREATE TABLE public.ride_sharing (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ride_id UUID NOT NULL REFERENCES public.rides(id) ON DELETE CASCADE,
  shared_with_name VARCHAR(100),
  shared_with_phone VARCHAR(20),
  tracking_url TEXT,
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.safety_incidents (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ride_id UUID REFERENCES public.rides(id),
  reported_by UUID NOT NULL REFERENCES public.users(id),
  incident_type VARCHAR(50) NOT NULL,
  description TEXT,
  location_lat DECIMAL(10,8),
  location_lng DECIMAL(11,8),
  status VARCHAR(20) DEFAULT 'REPORTED',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_safety_incidents_reported ON public.safety_incidents(reported_by);

-- ============================================
-- MESSAGING
-- ============================================
CREATE TABLE public.conversations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  type VARCHAR(20) NOT NULL,
  pool_id UUID REFERENCES public.pools(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.conversation_participants (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  last_read_at TIMESTAMPTZ,
  UNIQUE(conversation_id, user_id)
);

CREATE TABLE public.messages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  message_text TEXT,
  message_type VARCHAR(20) DEFAULT 'TEXT',
  is_system BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_messages_conv ON public.messages(conversation_id, created_at DESC);
CREATE INDEX idx_conv_participants_user ON public.conversation_participants(user_id);

-- ============================================
-- NOTIFICATIONS
-- ============================================
CREATE TABLE public.notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  title VARCHAR(255) NOT NULL,
  message TEXT NOT NULL,
  type VARCHAR(50) NOT NULL,
  is_read BOOLEAN DEFAULT FALSE,
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_notifications_user ON public.notifications(user_id, is_read) WHERE is_read = FALSE;

-- ============================================
-- AUDIT LOG
-- ============================================
CREATE TABLE public.audit_log (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  table_name VARCHAR(50) NOT NULL,
  record_id UUID NOT NULL,
  action VARCHAR(20) NOT NULL,
  old_data JSONB,
  new_data JSONB,
  changed_by UUID,
  ip_address INET,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_audit_log_table_record ON public.audit_log(table_name, record_id);
CREATE INDEX idx_audit_log_time ON public.audit_log USING BRIN(created_at);

-- ============================================
-- TRIGGERS FOR AUTO-CALCULATION
-- ============================================

-- Auto-update timestamps
CREATE OR REPLACE FUNCTION update_timestamp()
RETURNS TRIGGER AS '
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
' LANGUAGE plpgsql;

CREATE TRIGGER t_users_ts BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER t_wallets_ts BEFORE UPDATE ON public.wallets FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER t_saved_places_ts BEFORE UPDATE ON public.saved_places FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER t_vehicles_ts BEFORE UPDATE ON public.vehicles FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER t_pools_ts BEFORE UPDATE ON public.pools FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER t_rides_ts BEFORE UPDATE ON public.rides FOR EACH ROW EXECUTE FUNCTION update_timestamp();

-- Auto-calculate geography (H3 calculated by backend)
CREATE OR REPLACE FUNCTION calc_geography()
RETURNS TRIGGER AS '
BEGIN
  IF TG_TABLE_NAME = ''users'' THEN
    IF NEW.driver_priority_lat IS NOT NULL AND NEW.driver_priority_lng IS NOT NULL THEN
      NEW.driver_priority_location = ST_SetSRID(ST_MakePoint(NEW.driver_priority_lng, NEW.driver_priority_lat), 4326)::geography;
    END IF;
  ELSIF TG_TABLE_NAME = ''saved_places'' THEN
    NEW.location = ST_SetSRID(ST_MakePoint(NEW.lng, NEW.lat), 4326)::geography;
  ELSIF TG_TABLE_NAME = ''vehicle_locations'' THEN
    NEW.location = ST_SetSRID(ST_MakePoint(NEW.lng, NEW.lat), 4326)::geography;
  ELSIF TG_TABLE_NAME = ''pools'' THEN
    NEW.destination_location = ST_SetSRID(ST_MakePoint(NEW.destination_lng, NEW.destination_lat), 4326)::geography;
  ELSIF TG_TABLE_NAME = ''rides'' THEN
    NEW.pickup_location = ST_SetSRID(ST_MakePoint(NEW.pickup_lng, NEW.pickup_lat), 4326)::geography;
    NEW.dropoff_location = ST_SetSRID(ST_MakePoint(NEW.dropoff_lng, NEW.dropoff_lat), 4326)::geography;
  END IF;
  RETURN NEW;
END;
' LANGUAGE plpgsql;

CREATE TRIGGER t_users_geo BEFORE INSERT OR UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION calc_geography();
CREATE TRIGGER t_saved_places_geo BEFORE INSERT OR UPDATE ON public.saved_places FOR EACH ROW EXECUTE FUNCTION calc_geography();
CREATE TRIGGER t_vehicle_loc_geo BEFORE INSERT OR UPDATE ON public.vehicle_locations FOR EACH ROW EXECUTE FUNCTION calc_geography();
CREATE TRIGGER t_pools_geo BEFORE INSERT OR UPDATE ON public.pools FOR EACH ROW EXECUTE FUNCTION calc_geography();
CREATE TRIGGER t_rides_geo BEFORE INSERT OR UPDATE ON public.rides FOR EACH ROW EXECUTE FUNCTION calc_geography();

-- ============================================
-- RLS POLICIES (Security Only)
-- ============================================

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.saved_places ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emergency_contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vehicle_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pools ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pool_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.priyo_sathi ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.promo_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ride_sharing ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.safety_incidents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- Users: Own profile + pool members
CREATE POLICY p_users_own ON public.users FOR SELECT USING (auth.uid() = id);
CREATE POLICY p_users_pool ON public.users FOR SELECT USING (
  id IN (
    SELECT pm2.user_id FROM public.pool_members pm1
    JOIN public.pool_members pm2 ON pm1.pool_id = pm2.pool_id
    WHERE pm1.user_id = auth.uid() AND pm1.left_at IS NULL AND pm2.left_at IS NULL
  )
);
CREATE POLICY p_users_update ON public.users FOR UPDATE USING (auth.uid() = id);

-- Wallets: Own only
CREATE POLICY p_wallets ON public.wallets FOR ALL USING (auth.uid() = user_id);
CREATE POLICY p_wallet_txn ON public.wallet_transactions FOR SELECT USING (
  wallet_id IN (SELECT id FROM public.wallets WHERE user_id = auth.uid())
);

-- Saved places: Own only
CREATE POLICY p_saved_places ON public.saved_places FOR ALL USING (auth.uid() = user_id);

-- Emergency contacts: Own only
CREATE POLICY p_emergency ON public.emergency_contacts FOR ALL USING (auth.uid() = user_id);

-- Vehicles: Public read, own write
CREATE POLICY p_vehicles_read ON public.vehicles FOR SELECT USING (is_active = TRUE);
CREATE POLICY p_vehicles_write ON public.vehicles FOR ALL USING (auth.uid() = driver_id);

-- Vehicle locations: Pool members can see
CREATE POLICY p_vehicle_loc_driver ON public.vehicle_locations FOR ALL USING (auth.uid() = driver_id);
CREATE POLICY p_vehicle_loc_pool ON public.vehicle_locations FOR SELECT USING (
  pool_id IN (SELECT pool_id FROM public.pool_members WHERE user_id = auth.uid())
);

-- Pools: Public read available, own write
CREATE POLICY p_pools_read ON public.pools FOR SELECT USING (deleted_at IS NULL);
CREATE POLICY p_pools_create ON public.pools FOR INSERT WITH CHECK (auth.uid() = creator_user_id);
CREATE POLICY p_pools_update ON public.pools FOR UPDATE USING (
  auth.uid() = creator_user_id OR auth.uid() = driver_id
);

-- Rides: Own only
CREATE POLICY p_rides_own ON public.rides FOR ALL USING (auth.uid() = user_id);

-- Pool members: Can see own pool
CREATE POLICY p_pool_members_read ON public.pool_members FOR SELECT USING (
  pool_id IN (SELECT pool_id FROM public.pool_members WHERE user_id = auth.uid())
);
CREATE POLICY p_pool_members_join ON public.pool_members FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Priyo Sathi: Own connections
CREATE POLICY p_priyo_sathi ON public.priyo_sathi FOR ALL USING (
  auth.uid() = user_id OR auth.uid() = companion_id
);

-- Payments: Own only
CREATE POLICY p_payments ON public.payments FOR ALL USING (auth.uid() = user_id);

-- Promo codes: Public read
CREATE POLICY p_promo_read ON public.promo_codes FOR SELECT USING (is_active = TRUE);

-- Ratings: Public read, own write
CREATE POLICY p_ratings_read ON public.ratings FOR SELECT USING (true);
CREATE POLICY p_ratings_write ON public.ratings FOR INSERT WITH CHECK (auth.uid() = rater_id);

-- Safety: Own reports
CREATE POLICY p_ride_sharing ON public.ride_sharing FOR ALL USING (
  ride_id IN (SELECT id FROM public.rides WHERE user_id = auth.uid())
);
CREATE POLICY p_safety ON public.safety_incidents FOR ALL USING (auth.uid() = reported_by);

-- Messaging: Participants only
CREATE POLICY p_conversations ON public.conversations FOR SELECT USING (
  id IN (SELECT conversation_id FROM public.conversation_participants WHERE user_id = auth.uid())
);
CREATE POLICY p_messages_read ON public.messages FOR SELECT USING (
  conversation_id IN (SELECT conversation_id FROM public.conversation_participants WHERE user_id = auth.uid())
);
CREATE POLICY p_messages_write ON public.messages FOR INSERT WITH CHECK (
  auth.uid() = sender_id AND
  conversation_id IN (SELECT conversation_id FROM public.conversation_participants WHERE user_id = auth.uid())
);

-- Notifications: Own only
CREATE POLICY p_notifications ON public.notifications FOR ALL USING (auth.uid() = user_id);

-- ============================================
-- HELPER VIEWS (Read-Only)
-- ============================================

CREATE VIEW v_active_pools AS
SELECT
  p.id, p.creator_user_id, p.driver_id, p.status,
  p.destination_lat, p.destination_lng, p.destination_address,
  p.destination_h3_index,
  p.vehicle_type, p.gender_restriction,
  p.current_passengers, p.max_passengers,
  p.fare_per_person, p.viability_score,
  p.created_at,
  v.vehicle_number, v.model
FROM public.pools p
LEFT JOIN public.vehicles v ON v.id = p.vehicle_id
WHERE p.deleted_at IS NULL
AND p.status IN ('WAITING_FOR_RIDERS', 'WAITING_FOR_DRIVER', 'READY_TO_START', 'STARTED');

-- ============================================
-- COMMENTS AND DOCUMENTATION
-- ============================================

COMMENT ON TABLE public.pools IS 'Ride pools with H3 destination indexing for efficient matching (H3 calculated by backend using h3-js)';
COMMENT ON TABLE public.rides IS 'Individual ride requests with H3 pickup (res 9) and destination (res 7) indexes (backend calculated)';
COMMENT ON TABLE public.vehicle_locations IS 'Real-time vehicle locations with dual H3 indexes for driver search and pickup matching (backend calculated)';

COMMENT ON COLUMN public.pools.destination_h3_index IS 'H3 resolution 7 (~5.2km avg hexagon edge) for destination area matching - calculated by backend';
COMMENT ON COLUMN public.rides.pickup_h3_index IS 'H3 resolution 9 (~174m avg hexagon edge) for precise pickup location matching - calculated by backend';
COMMENT ON COLUMN public.rides.dropoff_h3_index IS 'H3 resolution 7 (~5.2km avg hexagon edge) for destination area matching - calculated by backend';
COMMENT ON COLUMN public.vehicle_locations.h3_index_res8 IS 'H3 resolution 8 (~461m avg hexagon edge) for driver search area - calculated by backend';
COMMENT ON COLUMN public.vehicle_locations.h3_index_res9 IS 'H3 resolution 9 (~174m avg hexagon edge) for precise driver location - calculated by backend';

-- ============================================
-- H3 RESOLUTION GUIDE
-- ============================================
-- Resolution | Avg Hexagon Edge | Use Case
-- -----------|------------------|---------------------------
-- 7          | ~5.2 km          | Destination area matching
-- 8          | ~461 m           | Driver search radius
-- 9          | ~174 m           | Pickup point matching
-- 10         | ~65 m            | Not used (too precise)
-- ============================================

-- ============================================
-- BACKEND IMPLEMENTATION NOTES
-- ============================================
/*
Since Supabase doesn't have H3 extension, use h3-js in your backend:

npm install h3-js

Example backend code (TypeScript/Node.js):

import { latLngToCell, gridDisk, cellToLatLng, gridDistance } from 'h3-js';

// When user creates a ride:
const pickupH3 = latLngToCell(pickup.lat, pickup.lng, 9);  // Resolution 9
const dropoffH3 = latLngToCell(dropoff.lat, dropoff.lng, 7); // Resolution 7

await supabase.from('rides').insert({
  user_id: userId,
  pickup_lat: pickup.lat,
  pickup_lng: pickup.lng,
  pickup_h3_index: pickupH3,
  dropoff_lat: dropoff.lat,
  dropoff_lng: dropoff.lng,
  dropoff_h3_index: dropoffH3,
  // ... other fields
});

// Find matching pools (same or nearby H3 hexagons):
const destinationRing = gridDisk(dropoffH3, 2); // Get hexagons within 2 rings

const { data: matchingPools } = await supabase
  .from('pools')
  .select('*')
  .in('destination_h3_index', destinationRing)
  .eq('status', 'WAITING_FOR_RIDERS')
  .eq('vehicle_type', vehicleType)
  .lt('current_passengers', 'max_passengers');

// Find nearby drivers:
const pickupRing = gridDisk(pickupH3, 2);

const { data: nearbyDrivers } = await supabase
  .from('vehicle_locations')
  .select('*, vehicles(*), users(*)')
  .in('h3_index_res9', pickupRing)
  .eq('is_active', true)
  .eq('is_available', true)
  .order('recorded_at', { ascending: false });

// Calculate H3 distance between two points:
const distance = gridDistance(hex1, hex2);

// Dynamic pooling - find riders near moving vehicle:
const vehicleH3 = latLngToCell(vehicleLat, vehicleLng, 9);
const searchArea = gridDisk(vehicleH3, 3); // ~500m radius

const { data: nearbyRiders } = await supabase
  .from('rides')
  .select('*')
  .in('pickup_h3_index', searchArea)
  .eq('status', 'CREATING_POOL');
*/

-- ============================================
-- SUCCESS! SCHEMA READY FOR SUPABASE
-- ============================================
-- All tables created with H3 index columns
-- Backend calculates H3 using h3-js library
-- Queries use indexed H3 columns for fast lookups
-- PostGIS handles geography calculations
-- ============================================