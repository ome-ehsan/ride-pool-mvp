import { Router } from 'express';
import { authenticate } from '../middleware/auth';

const router = Router();

router.get('/search', authenticate, async (req, res, next) => {
  try {
    res.json({ message: 'Search pools endpoint' });
  } catch (error) {
    next(error);
  }
});

router.post('/create', authenticate, async (req, res, next) => {
  try {
    res.json({ message: 'Create pool endpoint' });
  } catch (error) {
    next(error);
  }
});

router.post('/:poolId/join', authenticate, async (req, res, next) => {
  try {
    res.json({ message: 'Join pool endpoint' });
  } catch (error) {
    next(error);
  }
});

export default router;