import React from 'react';
import { NavigationContainer } from '@react-navigation/native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { AuthProvider } from './store/AuthContext';
import { PoolProvider } from './store/PoolContext';
import AppNavigator from './navigation/AppNavigator';

const App = () => {
  return (
    <SafeAreaProvider>
      <AuthProvider>
        <PoolProvider>
          <NavigationContainer>
            <AppNavigator />
          </NavigationContainer>
        </PoolProvider>
      </AuthProvider>
    </SafeAreaProvider>
  );
};

export default App;