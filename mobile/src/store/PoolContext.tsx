import React, { createContext, useContext, useState, ReactNode } from 'react';

interface Pool {
  id: string;
  driver_id: string;
  vehicle_type: string;
  status: string;
  current_passengers: number;
}

interface PoolContextType {
  currentPool: Pool | null;
  availablePools: Pool[];
  setCurrentPool: (pool: Pool | null) => void;
  setAvailablePools: (pools: Pool[]) => void;
}

const PoolContext = createContext<PoolContextType | undefined>(undefined);

export const PoolProvider = ({ children }: { children: ReactNode }) => {
  const [currentPool, setCurrentPool] = useState<Pool | null>(null);
  const [availablePools, setAvailablePools] = useState<Pool[]>([]);

  return (
    <PoolContext.Provider
      value={{
        currentPool,
        availablePools,
        setCurrentPool,
        setAvailablePools,
      }}
    >
      {children}
    </PoolContext.Provider>
  );
};

export const usePool = () => {
  const context = useContext(PoolContext);
  if (context === undefined) {
    throw new Error('usePool must be used within a PoolProvider');
  }
  return context;
};
