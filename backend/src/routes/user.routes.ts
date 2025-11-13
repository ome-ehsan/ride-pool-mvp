import { Router } from 'express';
import { authenticate } from '../middleware/auth';

const router = Router();

router.get('/profile', authenticate, async (req, res, next) => {
  try {
    res.json({ message: 'User profile endpoint', user: req.user });
  } catch (error) {
    next(error);
  }
});

router.put('/profile', authenticate, async (req, res, next) => {
  try {
    res.json({ message: 'Update profile endpoint' });
  } catch (error) {
    next(error);
  }
});

export default router;
