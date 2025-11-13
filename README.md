# Ride Pool MVP

A ride-pooling application for Dhaka City focused on cost savings through mandatory carpooling.

## Tech Stack

- **Frontend**: React Native (TypeScript)
- **Backend**: Express.js + Supabase
- **Database**: PostgreSQL (via Supabase)
- **Maps**: Google Maps API

## Project Structure

\`\`\`
ride-pool-mvp/
├── backend/          # Express.js API server
├── RidePoolMobile/   # React Native mobile app
└── supabase/         # Database migrations and config
\`\`\`

## Getting Started

### Prerequisites

- Node.js (v18 or higher)
- npm or yarn
- React Native development environment
- Supabase account
- Google Maps API key

### Setup

1. Clone the repository
2. Set up backend:
   \`\`\`bash
   cd backend
   cp .env.example .env
   # Fill in your environment variables
   npm install
   npm run dev
   \`\`\`

3. Set up mobile app:
   \`\`\`bash
   cd RidePoolMobile
   cp .env.example .env
   # Fill in your environment variables
   npm install
   # For iOS
   cd ios && pod install && cd ..
   npm run ios
   # For Android
   npm run android
   \`\`\`

   > 💡 **Android Devices:**  
   > Use your computer’s LAN IP instead of "localhost" for \`API_BASE_URL\`  
   > Example: \`http://192.168.x.x:3000/api\`

4. Set up database:
   \`\`\`bash
   cd supabase
   supabase link --project-ref your-project-ref
   supabase db push
   \`\`\`

## Development

- Backend runs on: http://localhost:3000
- Mobile app: Use Metro bundler

## Features (MVP)

- User authentication
- Pool matching
- Real-time location tracking
- Fare calculation
- Payment integration (bKash, Nagad)
- Priyo Sathi (preferred companions)
- Gender-based filtering

## License

MIT
