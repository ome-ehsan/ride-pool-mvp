import { Router } from 'express';
import { authenticate } from '../middleware/auth';

const router = Router();

router.post('/request', authenticate, async (req, res, next) => {
  try {
    res.json({ message: 'Request ride endpoint' });
  } catch (error) {
    next(error);
  }
});

router.get('/history', authenticate, async (req, res, next) => {
  try {
    res.json({ message: 'Ride history endpoint' });
  } catch (error) {
    next(error);
  }
});

router.put('/:rideId/cancel', authenticate, async (req, res, next) => {
  try {
    res.json({ message: 'Cancel ride endpoint' });
  } catch (error) {
    next(error);
  }
});

export default router;