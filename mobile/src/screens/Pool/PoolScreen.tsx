import React from 'react';
import { View, Text, StyleSheet } from 'react-native';

const PoolScreen = () => {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Pool Screen</Text>
      <Text>Find and join pools here</Text>
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

export default PoolScreen;
