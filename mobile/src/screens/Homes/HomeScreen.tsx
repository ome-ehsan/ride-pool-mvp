import React from 'react';
import { View, Text, StyleSheet, TouchableOpacity } from 'react-native';
import { useLocation } from '../../hooks/useLocation';

const HomeScreen = ({ navigation }: any) => {
  const { location, loading, error } = useLocation();

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Home</Text>
      {loading && <Text>Getting location...</Text>}
      {error && <Text>Error: {error}</Text>}
      {location && (
        <Text>
          Lat: {location.latitude.toFixed(6)}, Lng: {location.longitude.toFixed(6)}
        </Text>
      )}
      <TouchableOpacity
        style={styles.button}
        onPress={() => navigation.navigate('Pool')}
      >
        <Text style={styles.buttonText}>Find a Pool</Text>
      </TouchableOpacity>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 20,
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold',
    marginBottom: 20,
  },
  button: {
    backgroundColor: '#007AFF',
    padding: 15,
    borderRadius: 8,
    marginTop: 20,
  },
  buttonText: {
    color: '#fff',
    fontSize: 16,
  },
});

export default HomeScreen;
