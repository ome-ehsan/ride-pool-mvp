import React from 'react';
import { View, Text, StyleSheet } from 'react-native';

const RideScreen = () => {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Ride Screen</Text>
      <Text>View your current and past rides</Text>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold',
    marginBottom: 20,
  },
});

export default RideScreen;